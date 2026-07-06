#!/usr/bin/env bash
# argus-regress — regression sweep over Argus-filed GitHub issues.
#
# Closes the QA loop: pulls open Argus-labeled issues, replays each issue's
# reproduction steps in a FRESH agent session, and posts a dated comment with
# the verdict (still-reproduces / appears-fixed / unable-to-verify) and a
# screenshot. Issues are never closed unless --close (or ARGUS_REGRESS_CLOSE
# =true in /opt/data/.env) — a single replay has a real false-fixed rate, and
# a wrongly closed issue silently vanishes from the board.
#
#   argus-regress                      # sweep ALL open Argus issues, oldest first
#   argus-regress 10173 10175          # replay exactly these issues
#   argus-regress --limit 5            # first 5 (oldest) only
#   argus-regress --close              # auto-close issues that appear fixed
#   argus-regress --provider auto -m gpt-4.1   # replay against a cloud model
# Runs use the local gemma variant by default (--provider local -m gemma4-argus64k);
# --model / --provider override it. --local is a back-compat no-op alias.
#
# Division of labour (same decide/execute split as argus-file-issues):
#   SCRIPT: pulls issues via gh, parses viewport/persona out of each body,
#           launches one session per issue, uploads the screenshot, posts the
#           comment, optionally closes. Every GitHub call is deterministic.
#   AGENT:  browses only — follows the steps, judges the verdict, writes
#           /opt/data/run/verdict.md. It never has GitHub auth.
#
# One session per issue, not one session for all: verdicts must come from
# clean context holding exactly one issue's steps (compressed long sessions
# fabricate), and the per-issue launch is what lets the harness set the
# issue's own viewport env before the browser starts.
#
# Regression runs are LEDGER-NEUTRAL: qa-notes is never read or written.

set -euo pipefail

SITE="remundo"
SITE_HOST="dev.xml.remundo.com"
REPO="remundo-xml/Remundo.Ui.Platform"
RUN_DIR="/opt/data/run"
WORK="/tmp/argus-regress"

ISSUE_NUMS=()
LIMIT=""
PERSONA_OVERRIDE=""
MAX_TURNS=60
# Model + provider both default to the local gemma variant and are independently
# overridable (--model / --provider). Same baked-num_ctx rationale as argus-test
# — see its header. PROVIDER_FLAGS is assembled after parsing; for a cloud box:
# --provider auto -m gpt-4.1.
PROVIDER="local"
MODEL="gemma4-argus64k"
# Per-issue wall-clock cap. A replay is a short, scripted walk (login + a few
# steps + one screenshot) — far less than a QA session's 2400s.
REGRESS_TIMEOUT="${REGRESS_TIMEOUT:-1200}"
CLOSE_FIXED="$(grep -E '^ARGUS_REGRESS_CLOSE=' /opt/data/.env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]' || true)"
CLOSE_FIXED="${CLOSE_FIXED:-false}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)
      # Back-compat alias: local gemma is now the default, so this is a no-op.
      PROVIDER="local"; MODEL="gemma4-argus64k"; shift ;;
    --model|-m)
      MODEL="$2"; shift 2 ;;
    --provider)
      PROVIDER="$2"; shift 2 ;;
    --max-turns)
      MAX_TURNS="$2"; shift 2 ;;
    --limit)
      LIMIT="$2"; shift 2 ;;
    --persona)
      # Override the persona parsed from each issue body.
      PERSONA_OVERRIDE="$2"; shift 2 ;;
    --watch)
      export ARGUS_HEADED=true; shift ;;
    --close)
      CLOSE_FIXED=true; shift ;;
    --no-close)
      CLOSE_FIXED=false; shift ;;
    -*)
      echo "Unknown flag: $1"; exit 1 ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        ISSUE_NUMS+=("$1")
      else
        echo "✗ Positional args must be issue numbers, got: $1"; exit 1
      fi
      shift ;;
  esac
done

# Assemble the provider flags forwarded to every replay session.
PROVIDER_FLAGS="--provider $PROVIDER -m $MODEL"

ARGUS_GITHUB_TOKEN="$(grep -E '^ARGUS_GITHUB_TOKEN=' /opt/data/.env 2>/dev/null | tail -1 | cut -d= -f2- || true)"
if [[ -z "$ARGUS_GITHUB_TOKEN" ]]; then
  echo "✗ ARGUS_GITHUB_TOKEN is not set in /opt/data/.env"
  exit 1
fi

if [[ "$PROVIDER" == "local" ]]; then
  echo "▶ Checking Ollama connectivity ($MODEL)..."
  if ! curl -sf --max-time 3 http://localhost:11434/api/tags > /dev/null 2>&1; then
    echo "✗ Ollama is not reachable. Start it with: OLLAMA_HOST=0.0.0.0 ollama serve &"
    exit 1
  fi
  echo "  ✓ Ollama is up"
fi

# gh auth via hosts.yml in the agent-subprocess HOME, retried for the
# intermittent PAT 401, logged out on exit — same as argus-file-issues.
SUBPROC_HOME=/opt/data/home
mkdir -p "$SUBPROC_HOME"
auth_ok=false
for attempt in 1 2 3 4 5; do
  if printf '%s\n' "$ARGUS_GITHUB_TOKEN" | HOME="$SUBPROC_HOME" gh auth login --with-token --hostname github.com 2>/dev/null; then
    auth_ok=true
    break
  fi
  echo "  gh auth validation failed (attempt $attempt) — retrying..."
  sleep 2
done
if [[ "$auth_ok" != "true" ]]; then
  echo "✗ Could not authenticate gh with ARGUS_GITHUB_TOKEN after 5 attempts"
  exit 1
fi
trap 'HOME="$SUBPROC_HOME" gh auth logout --hostname github.com >/dev/null 2>&1 || true' EXIT
echo "▶ gh authenticated for sweep window"

source /opt/hermes/.venv/bin/activate

# ── Fetch the issues to sweep ──────────────────────────────────────────────
rm -rf "$WORK"; mkdir -p "$WORK"
if [[ ${#ISSUE_NUMS[@]} -gt 0 ]]; then
  # Explicit numbers: fetch each directly (any state — replaying a closed
  # issue to sanity-check a fix is a legitimate ask).
  echo "[" > "$WORK/issues.json"
  first=true
  for n in "${ISSUE_NUMS[@]}"; do
    if body="$(HOME="$SUBPROC_HOME" gh issue view "$n" -R "$REPO" --json number,title,body,state,createdAt 2>/dev/null)"; then
      if [[ "$first" != "true" ]]; then echo "," >> "$WORK/issues.json"; fi
      printf '%s' "$body" >> "$WORK/issues.json"
      first=false
    else
      echo "  ⚠ could not fetch issue #$n — skipping"
    fi
  done
  echo "]" >> "$WORK/issues.json"
else
  HOME="$SUBPROC_HOME" gh issue list -R "$REPO" --label Argus --state open --limit 200 \
    --json number,title,body,state,createdAt > "$WORK/issues.json" 2>/dev/null \
    || { echo "✗ Could not list Argus issues"; exit 1; }
fi

# Per issue: a cleaned issue.md for the agent (inline screenshots stripped —
# the replayer follows steps, it does not need the old image) and a meta file
# the script reads back (viewport parsed from the body's 'Viewport:' line or
# 'set the browser viewport to WxH' step; persona from 'the X test persona').
mapfile -t SWEEP_NUMS < <(python3 - "$WORK" "${LIMIT:-0}" <<'PYEOF'
import json, re, sys, os
work, limit = sys.argv[1], int(sys.argv[2])
issues = json.load(open(os.path.join(work, "issues.json")))
issues.sort(key=lambda i: i.get("createdAt", ""))
if limit > 0:
    issues = issues[:limit]
for it in issues:
    num, title, body = it["number"], it.get("title", ""), it.get("body", "") or ""
    d = os.path.join(work, f"issue-{num}")
    os.makedirs(d, exist_ok=True)
    clean = "\n".join(l for l in body.splitlines() if not re.match(r"\s*!\[", l))
    with open(os.path.join(d, "issue.md"), "w") as f:
        f.write(f"# {title}\n\n(GitHub issue #{num})\n\n{clean}\n")
    m = re.search(r"[Vv]iewport[^\d]{0,24}(\d{2,4})\s*x\s*(\d{2,4})", body)
    vw, vh = (m.group(1), m.group(2)) if m else ("", "")
    p = re.search(r"the ([a-z][a-z-]*) test persona", body, re.I) \
        or re.search(r"persona '([^']+)'", body)
    persona = p.group(1).lower() if p else "candidate"
    with open(os.path.join(d, "meta"), "w") as f:
        f.write(f"viewport_w={vw}\nviewport_h={vh}\npersona={persona}\n")
        f.write(f"state={it.get('state','')}\ntitle={title}\n")
    print(num)
PYEOF
)

if [[ ${#SWEEP_NUMS[@]} -eq 0 ]]; then
  echo "▶ No open Argus issues to sweep — nothing to do."
  exit 0
fi
echo "▶ Regression sweep: ${#SWEEP_NUMS[@]} issue(s) — ${SWEEP_NUMS[*]}"
if [[ "$CLOSE_FIXED" == "true" ]]; then
  echo "▶ Auto-close is ON: issues that appear fixed will be closed as completed."
fi
echo ""

STAMP="$(date +%Y%m%d-%H%M)"
SWEEP_DATE="$(date +%F)"
REPORT_FILE="/opt/data/reports/regress-${STAMP}.md"
ARCHIVE_DIR="/opt/data/reports/parts/regress-${STAMP}"
mkdir -p /opt/data/reports/screenshots "$ARCHIVE_DIR"

ARTIFACTS_REPO="$(grep -E '^ARGUS_ARTIFACTS_REPO=' /opt/data/.env 2>/dev/null | tail -1 | cut -d= -f2- || true)"
ARTIFACTS_REPO="${ARTIFACTS_REPO:-remundo-xml/argus-artifacts}"
ARTIFACTS_TOKEN="$(grep -E '^ARGUS_ARTIFACTS_TOKEN=' /opt/data/.env 2>/dev/null | tail -1 | cut -d= -f2- || true)"

upload_shot() {  # $1 local path → prints raw URL, rc 1 on failure
  local dest
  dest="screenshots/$(date +%Y-%m)/$(date +%Y%m%d-%H%M%S)-$(basename "$1")"
  python3 - "$1" "$dest" "$ARTIFACTS_REPO" "$ARTIFACTS_TOKEN" <<'PYEOF'
import base64, json, sys, time, urllib.request
src, dest, repo, token = sys.argv[1:5]
with open(src, "rb") as f:
    b64 = base64.b64encode(f.read()).decode()
body = json.dumps({"message": f"Argus screenshot {dest}", "content": b64}).encode()
last = None
for attempt in range(5):  # GitHub intermittently 401s fresh fine-grained PATs
    req = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/contents/{dest}",
        data=body, method="PUT",
        headers={"Authorization": f"Bearer {token}",
                 "Accept": "application/vnd.github+json"})
    try:
        with urllib.request.urlopen(req) as r:
            print(json.load(r)["content"]["download_url"])
            sys.exit(0)
    except Exception as e:
        last = e
        time.sleep(2)
print(f"upload failed: {last}", file=sys.stderr)
sys.exit(1)
PYEOF
}

SITE_CONFIG="/opt/data/skills/site-config/SKILL.md"
persona_email() {
  awk -v p="$1" '
    tolower($0) ~ ("^### persona: " tolower(p) "$") {f=1; next}
    /^### / {f=0}
    f && /^- *Email:/ {sub(/^- *Email:[ \t]*/,""); gsub(/[ \t]+$/,""); print; exit}' "$SITE_CONFIG" 2>/dev/null || true
}
persona_pw() {
  awk -v p="$1" '
    tolower($0) ~ ("^### persona: " tolower(p) "$") {f=1; next}
    /^### / {f=0}
    f && /^- *Password:/ {sub(/^- *Password:[ \t]*/,""); gsub(/[ \t]+$/,""); print; exit}' "$SITE_CONFIG" 2>/dev/null || true
}

# From here down is the sweep itself — best-effort per issue. One issue's
# failed session, upload or comment must never abort the remaining issues
# (the set-e-kills-post-run class of bug, pre-empted this time).
set +e

{
  echo "# ${SITE} regression sweep — $(date '+%Y-%m-%d %H:%M')"
  echo
} > "$REPORT_FILE"

still=0; fixed=0; unable=0
for num in "${SWEEP_NUMS[@]}"; do
  META="$WORK/issue-$num/meta"
  VP_W="$(sed -n 's/^viewport_w=//p' "$META")"
  VP_H="$(sed -n 's/^viewport_h=//p' "$META")"
  ISSUE_STATE="$(sed -n 's/^state=//p' "$META")"
  ISSUE_TITLE="$(sed -n 's/^title=//p' "$META")"
  PERSONA="${PERSONA_OVERRIDE:-$(sed -n 's/^persona=//p' "$META")}"
  PERSONA="${PERSONA:-candidate}"

  VIEWPORT_NOTE=""
  VIEWPORT_LINE=""
  if [[ -n "$VP_W" && -n "$VP_H" ]]; then
    VIEWPORT_NOTE=" The harness has already set the browser viewport to ${VP_W}x${VP_H} as the issue requires — do NOT change it, and skip any step that says to set the viewport. Judge the page as a user on a screen this size (hamburger navigation and vertical stacking are normal, not bugs)."
    VIEWPORT_LINE="Viewport: ${VP_W}x${VP_H}"
    echo "▶ Issue #$num: '$ISSUE_TITLE' (persona: ${PERSONA}, viewport: ${VP_W}x${VP_H})"
  else
    echo "▶ Issue #$num: '$ISSUE_TITLE' (persona: ${PERSONA})"
  fi

  LOGIN_EMAIL="$(persona_email "$PERSONA")"
  LOGIN_PW="$(persona_pw "$PERSONA")"
  if [[ -n "$LOGIN_EMAIL" && -n "$LOGIN_PW" ]]; then
    CRED_LINE="Use ONLY these credentials (never invent or substitute any): email '${LOGIN_EMAIL}', password '${LOGIN_PW}'."
  else
    CRED_LINE="Use ONLY the persona '${PERSONA}' credentials from the site-config skill — never invent or substitute any."
  fi
  LOGIN_STEP="Log in to https://${SITE_HOST} as persona '${PERSONA}' before anything else, following the 'Logging in' procedure in the web-qa-workflow skill. ${CRED_LINE} In short: open the site's login page, browser_snapshot it, browser_type the email and password into their fields, read each value back to confirm it stuck (if a field is empty your ref went stale — re-snapshot and type again), browser_click the submit button, then confirm the URL has left the login page. If you land on a setup/MFA/consent interstitial that is not the app itself, click its skip / later / dismiss control. These credentials are valid, so a 'sign-in failed' message means the value did not register (stale ref) — re-snapshot and retype; never try other credentials or other login methods."

  rm -rf "$RUN_DIR"
  mkdir -p "$RUN_DIR"
  cp "$WORK/issue-$num/issue.md" "$RUN_DIR/issue.md"

  SHOT="/opt/data/reports/screenshots/regress-${num}.png"
  rm -f "$SHOT"

  REGRESS_PROMPT="You are re-verifying ONE previously filed bug in the ${SITE} web app — a regression check, NOT a QA sweep. Do not explore, do not test anything beyond this issue's reproduction steps, and do not record new bugs.

Before you start:
- Load these skills with skill_view: 'site-config', 'web-qa-workflow'
- Read /opt/data/run/issue.md with read_file — the GitHub issue you are verifying: title, steps to reproduce, expected and actual behaviour.

Rules:
- Work through the browser UI only, like a real user. The ONLY valid site domain is https://${SITE_HOST} — if you remember any other domain, it is wrong.
- You are NOT testing the login flow. If you get redirected to /login mid-run, repeat the login procedure to get back in — routine, not a finding.
- Do not ask for direction. Never end your turn by announcing what you will do next — keep calling tools until verdict.md is written.
- Use browser_snapshot to read pages; call browser_vision only for the verdict screenshot.${VIEWPORT_NOTE}

Process:
1. ${LOGIN_STEP}
2. Follow the issue's 'Steps to reproduce' EXACTLY, in order.
3. At the decisive step, compare what you observe against the issue's Expected and Actual behaviour.
4. Capture the decisive state: call browser_vision — its result contains a screenshot_path — then run in terminal: cp <that screenshot_path> ${SHOT}
5. Write /opt/data/run/verdict.md with write_file, containing EXACTLY these three parts:
   VERDICT: <one of: still-reproduces | appears-fixed | unable-to-verify — the bare token alone on this line>
   OBSERVED: <2-4 factual sentences: what you saw at the decisive step>
   Screenshot: ${SHOT}

Verdict rules — be strict:
- still-reproduces: you followed the steps and observed the same faulty behaviour the issue's 'Actual behaviour' describes.
- appears-fixed: you completed EVERY step and observed the issue's 'Expected behaviour'. If you could not complete the steps, that is NOT appears-fixed.
- unable-to-verify: the steps could not be followed (page gone, control missing, login failed, required data missing) — state exactly why in OBSERVED.

Your final message comes only after verdict.md is written."

  NUDGE_PROMPT="You stopped before finishing. Do not ask the user anything — you are autonomous. Continue the regression check of the one issue in /opt/data/run/issue.md: follow its steps, capture the screenshot to ${SHOT}, and write /opt/data/run/verdict.md (VERDICT: / OBSERVED: / Screenshot: as originally instructed). Nothing else is in scope."

  VP_ENV=()
  if [[ -n "$VP_W" && -n "$VP_H" ]]; then
    VP_ENV=(ARGUS_BROWSER_VIEWPORT_W="$VP_W" ARGUS_BROWSER_VIEWPORT_H="$VP_H")
  fi
  # shellcheck disable=SC2086
  env "${VP_ENV[@]}" timeout --signal=TERM --kill-after=30 "$REGRESS_TIMEOUT" \
    argus chat --max-turns "$MAX_TURNS" \
    -t browser,skills_ro,file,terminal \
    -q "$REGRESS_PROMPT" \
    $PROVIDER_FLAGS || echo "⚠ agent session exited abnormally — continuing"

  NUDGES=0
  while [[ ! -f "$RUN_DIR/verdict.md" && $NUDGES -lt 2 ]]; do
    NUDGES=$((NUDGES + 1))
    echo "▶ No verdict yet — continuing session (nudge $NUDGES/2)..."
    # shellcheck disable=SC2086
    env "${VP_ENV[@]}" timeout --signal=TERM --kill-after=30 "$REGRESS_TIMEOUT" \
      argus chat --continue --max-turns "$MAX_TURNS" \
      -t browser,skills_ro,file,terminal \
      -q "$NUDGE_PROMPT" \
      $PROVIDER_FLAGS || echo "⚠ agent session exited abnormally — continuing"
  done

  # Parse the verdict. Anything missing or malformed is posted as
  # unable-to-verify — a wedged replay must be visible on the issue, not
  # silently skipped (the comment trail doubles as the sweep's heartbeat).
  VERDICT="$(sed -n 's/^VERDICT:[[:space:]]*//p' "$RUN_DIR/verdict.md" 2>/dev/null | head -1 \
             | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z-')"
  case "$VERDICT" in
    still-reproduces|appears-fixed|unable-to-verify) ;;
    *) VERDICT="unable-to-verify" ;;
  esac
  OBSERVED="$(awk '/^OBSERVED:/{sub(/^OBSERVED:[[:space:]]*/,""); p=1} /^Screenshot:/{p=0} p' "$RUN_DIR/verdict.md" 2>/dev/null)"
  if [[ -z "$OBSERVED" ]]; then
    OBSERVED="The replay session ended without producing a usable verdict — needs a human look or a re-run."
  fi

  SHOT_MD=""
  if [[ -f "$SHOT" && -n "$ARTIFACTS_TOKEN" ]]; then
    if url="$(upload_shot "$SHOT")"; then
      SHOT_MD="![screenshot](${url})"
    else
      echo "  ⚠ screenshot upload failed for #$num — commenting without image"
    fi
  elif [[ -f "$SHOT" ]]; then
    echo "  ⚠ ARGUS_ARTIFACTS_TOKEN not set — commenting without image"
  fi

  case "$VERDICT" in
    still-reproduces) HEAD="🔴 Still reproduces"; still=$((still + 1)) ;;
    appears-fixed)    HEAD="🟢 Appears fixed";    fixed=$((fixed + 1)) ;;
    *)                HEAD="⚪ Unable to verify"; unable=$((unable + 1)) ;;
  esac
  COMMENT_FILE="$WORK/issue-$num/comment.md"
  {
    echo "**Argus regression sweep ${SWEEP_DATE} — ${HEAD}**"
    echo
    echo "$OBSERVED"
    if [[ -n "$VIEWPORT_LINE" ]]; then echo; echo "$VIEWPORT_LINE"; fi
    if [[ -n "$SHOT_MD" ]]; then echo; echo "$SHOT_MD"; fi
  } > "$COMMENT_FILE"

  if HOME="$SUBPROC_HOME" gh issue comment "$num" -R "$REPO" --body-file "$COMMENT_FILE" >/dev/null 2>&1; then
    echo "  + commented on #$num: $VERDICT"
  else
    sleep 2  # retry once for the intermittent PAT 401
    if HOME="$SUBPROC_HOME" gh issue comment "$num" -R "$REPO" --body-file "$COMMENT_FILE" >/dev/null 2>&1; then
      echo "  + commented on #$num (retry): $VERDICT"
    else
      echo "  ⚠ failed to comment on #$num"
    fi
  fi

  if [[ "$CLOSE_FIXED" == "true" && "$VERDICT" == "appears-fixed" && "$ISSUE_STATE" != "CLOSED" ]]; then
    # Closed as completed — the filer's dedupe treats a COMPLETED close as
    # 'refile as regression' if a later QA run finds the bug again.
    if HOME="$SUBPROC_HOME" gh issue close "$num" -R "$REPO" --reason completed >/dev/null 2>&1; then
      echo "  + closed #$num as completed"
    else
      echo "  ⚠ failed to close #$num"
    fi
  fi

  {
    echo "## #${num} — ${ISSUE_TITLE}"
    echo
    echo "Verdict: ${VERDICT}"
    echo
    echo "$OBSERVED"
    if [[ -n "$VIEWPORT_LINE" ]]; then echo; echo "$VIEWPORT_LINE"; fi
    echo
    echo "---"
    echo
  } >> "$REPORT_FILE"

  mv "$RUN_DIR" "$ARCHIVE_DIR/issue-$num" 2>/dev/null || true
done

echo ""
echo "▶ Sweep complete: ${still} still reproduce, ${fixed} appear fixed, ${unable} unable to verify"
echo "▶ Sweep report: $REPORT_FILE"
