#!/usr/bin/env bash
# argus-file-issues — file bugs from a QA report as GitHub issues.
#
# Runs a small, focused agent session: reads the report, dedupes against
# existing Argus-labeled issues, files only reproduced bugs. Called by
# argus-test when issue filing is enabled, or standalone on any past report:
#
#   argus-file-issues /opt/data/reports/expenses-20260610-1349.md --local
#
# GH_TOKEN is read from ARGUS_GITHUB_TOKEN in /opt/data/.env and exported
# only for this process — gh in the main QA agent stays unauthenticated.

set -euo pipefail

REPO="remundo-xml/Remundo.Ui.Platform"
REPORT_FILE=""
PROVIDER_FLAGS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)
      PROVIDER_FLAGS="--provider local -m qwen3.6:35b"
      shift ;;
    --provider|-m|--max-turns)
      # pass-through (argus-test forwards its expanded provider flags)
      PROVIDER_FLAGS="$PROVIDER_FLAGS $1 $2"
      shift 2 ;;
    -*)
      echo "Unknown flag: $1"
      exit 1 ;;
    *)
      REPORT_FILE="$1"
      shift ;;
  esac
done

if [[ -z "$REPORT_FILE" || ! -f "$REPORT_FILE" ]]; then
  echo "Usage: argus-file-issues <report-file> [--local]"
  echo "Reports:"
  ls /opt/data/reports/ 2>/dev/null || echo "  (none found)"
  exit 1
fi

ARGUS_GITHUB_TOKEN="$(grep -E '^ARGUS_GITHUB_TOKEN=' /opt/data/.env 2>/dev/null | tail -1 | cut -d= -f2- || true)"
if [[ -z "$ARGUS_GITHUB_TOKEN" ]]; then
  echo "✗ ARGUS_GITHUB_TOKEN is not set in /opt/data/.env"
  exit 1
fi

# Authenticate gh via its own config in the agent-subprocess HOME
# (/opt/data/home) rather than env vars: env propagation into the terminal
# sandbox proved flaky, while hosts.yml is read deterministically.
# Logged out again on exit so gh is only authenticated during the filing
# window — the main QA agent never has working GitHub auth.
SUBPROC_HOME=/opt/data/home
mkdir -p "$SUBPROC_HOME"
# GitHub intermittently 401s freshly-created fine-grained PATs (auth backend
# replication) — retry validation a few times before giving up.
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
echo "▶ gh authenticated for filing window"

source /opt/hermes/.venv/bin/activate

RUN_DATE="$(date +%Y-%m-%d)"
REPORT_NAME="$(basename "$REPORT_FILE")"
rm -f /tmp/argus-filed-issues.md  # stale summary from a previous run

# ── Screenshot upload (inline images in issues) ───────────────────────────
# GitHub has no API for issue attachments, so screenshots referenced in the
# report are uploaded to a PUBLIC artifacts repo via the Contents API and
# the local paths replaced with raw URLs in a temp copy of the report. The
# agent then embeds them as ![..](url) — GitHub's camo proxy renders any
# publicly fetchable URL inline. Done here in the script, not by the agent.
ARTIFACTS_REPO="$(grep -E '^ARGUS_ARTIFACTS_REPO=' /opt/data/.env 2>/dev/null | tail -1 | cut -d= -f2- || true)"
ARTIFACTS_REPO="${ARTIFACTS_REPO:-remundo-xml/argus-artifacts}"
ARTIFACTS_TOKEN="$(grep -E '^ARGUS_ARTIFACTS_TOKEN=' /opt/data/.env 2>/dev/null | tail -1 | cut -d= -f2- || true)"

FILER_REPORT="$REPORT_FILE"
mapfile -t SCREENSHOTS < <(grep -oE '/opt/data/reports/screenshots/[A-Za-z0-9._-]+\.(png|jpg|jpeg)' "$REPORT_FILE" | sort -u)

if [[ ${#SCREENSHOTS[@]} -gt 0 && -z "$ARTIFACTS_TOKEN" ]]; then
  echo "▶ Report references ${#SCREENSHOTS[@]} screenshot(s) but ARGUS_ARTIFACTS_TOKEN is not set — issues will be filed without images."
elif [[ ${#SCREENSHOTS[@]} -gt 0 ]]; then
  FILER_REPORT="/tmp/argus-report-for-filing.md"
  cp "$REPORT_FILE" "$FILER_REPORT"
  uploaded=0
  for shot in "${SCREENSHOTS[@]}"; do
    [[ -f "$shot" ]] || { echo "  ⚠ referenced screenshot missing: $shot"; continue; }
    dest="screenshots/$(date +%Y-%m)/$(date +%Y%m%d-%H%M%S)-$(basename "$shot")"
    url="$(python3 - "$shot" "$dest" "$ARTIFACTS_REPO" "$ARTIFACTS_TOKEN" <<'PYEOF'
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
)" || { echo "  ⚠ upload failed for $shot — leaving local path"; continue; }
    sed -i "s|$shot|$url|g" "$FILER_REPORT"
    uploaded=$((uploaded + 1))
  done
  echo "▶ Uploaded $uploaded/${#SCREENSHOTS[@]} screenshot(s) to $ARTIFACTS_REPO"
fi

# Labels: 'Argus' is always applied (dedupe depends on it). Extra labels are
# per-deployment config, e.g. ARGUS_EXTRA_LABELS=salmons or =triage,frontend.
EXTRA_LABELS="$(grep -E '^ARGUS_EXTRA_LABELS=' /opt/data/.env 2>/dev/null | tail -1 | cut -d= -f2- || true)"
LABEL_FLAGS="--label Argus"
IFS=',' read -ra _extra <<< "$EXTRA_LABELS"
for _l in "${_extra[@]}"; do
  _l="$(echo "$_l" | xargs)"
  if [[ -n "$_l" ]]; then LABEL_FLAGS="$LABEL_FLAGS --label \"$_l\""; fi
done

# ── Decide / execute split ────────────────────────────────────────────────
# The agent DECIDES (pure judgment + writing files, which it does reliably);
# the SCRIPT EXECUTES every gh call (deterministic). A filer run once analysed
# all bugs, wrote the plan in prose, and ended its turn having created ZERO
# issues — same prompt that worked the next run. Never trust the model to
# carry out a sequence of side-effecting commands.
DECIDE_DIR=/tmp/argus-decide
rm -rf "$DECIDE_DIR"; mkdir -p "$DECIDE_DIR"
# Script runs the read-only dedup query (reliable) and hands it to the agent.
HOME="$SUBPROC_HOME" gh issue list -R "$REPO" --label Argus --state all --limit 200 \
  --json number,title,state,stateReason > "$DECIDE_DIR/existing-issues.json" 2>/dev/null \
  || echo "[]" > "$DECIDE_DIR/existing-issues.json"

# shellcheck disable=SC2086
argus chat --max-turns 80 -t file \
  -q "You are triaging QA bugs for GitHub filing. You do NOT touch GitHub — you only read files and WRITE decision files. A later step does the actual filing.

Step 1 — read the bug report at ${FILER_REPORT} with read_file. Each bug is a '## ' section.
Step 2 — read ${DECIDE_DIR}/existing-issues.json with read_file — the Argus issues already on GitHub.

Step 3 — for each '## ' bug section in the report, decide FILE or SKIP:
- SKIP if not actually reproduced (no concrete steps + observed result, or marked 'needs verification'/'not tested').
- SKIP if it duplicates another bug in THIS SAME report (file only the first).
- SKIP if an OPEN existing issue already describes the same bug, even on a different page or worded differently (same root defect = duplicate).
- SKIP if a CLOSED existing issue with stateReason NOT_PLANNED describes it.
- FILE otherwise. If a CLOSED existing issue with stateReason COMPLETED describes it, file it and start the body with 'Regression — previously fixed in #<number>'.

Step 4 — for each bug you decide to FILE, write ${DECIDE_DIR}/file-NN.md (NN = 01, 02, ...) with EXACTLY this structure:
TITLE: <short factual title, no prefixes/tags>
SECURITY: <yes if XSS/injection/auth-bypass, else no>
---
<issue body: the bug's URL, steps to reproduce, expected, actual, severity — copied from the report. If the section has a 'Screenshot:' line with an https URL, include the image with ![screenshot](<url>).>

Step 5 — write ${DECIDE_DIR}/_summary.md: a '## Filed issues' list (one line per bug you chose to FILE, by title) and a '## Skipped' list (each skipped bug + the reason / duplicate #number).

Write every file with write_file. Do not run any terminal or gh commands. Your final message: how many you marked FILE vs SKIP." \
  $PROVIDER_FLAGS || echo "⚠ decide step exited abnormally — proceeding with whatever decision files exist"

# Timestamp before any create — anything Argus-labeled after this is "this run".
FILING_START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Deterministic exact-title dedup safety net: the model's semantic dedup is
# best-effort and non-deterministic — it once re-filed a bug under a title
# IDENTICAL to an existing issue. Never create an issue whose title (case/space
# -normalised) already exists. Semantic near-dupes still rely on the agent.
norm() { echo "$1" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'; }
EXISTING_TITLES="$(python3 -c "
import json
try: data=json.load(open('$DECIDE_DIR/existing-issues.json'))
except Exception: data=[]
for i in data: print(i.get('title',''))
" 2>/dev/null)"
declare -A EXISTING_NORM=()
while IFS= read -r t; do [[ -n "$t" ]] && EXISTING_NORM["$(norm "$t")"]=1; done <<< "$EXISTING_TITLES"

# Script executes the creates deterministically from the decision files.
# Capture each created issue's number from the returned URL so decoration
# targets exactly these — no timestamp re-query (which raced GitHub's index
# and missed the last-created issue, leaving it undecorated).
filed=0
CREATED_NUMS=()
shopt -s nullglob
for df in "$DECIDE_DIR"/file-*.md; do
  title="$(sed -n 's/^TITLE:[[:space:]]*//p' "$df" | head -1)"
  security="$(sed -n 's/^SECURITY:[[:space:]]*//p' "$df" | head -1)"
  # body = everything after the first '---' line
  body_file="$df.body"
  awk 'p{print} /^---/{p=1}' "$df" > "$body_file"
  [[ -n "$title" && -s "$body_file" ]] || { echo "  ⚠ skipping malformed decision file $df"; continue; }
  if [[ -n "${EXISTING_NORM["$(norm "$title")"]:-}" ]]; then
    echo "  = skip (title already exists): $title"
    continue
  fi
  sec_label=""
  case "$security" in [Yy]es|true|TRUE) sec_label='--label Security' ;; esac
  # shellcheck disable=SC2086
  if url=$(HOME="$SUBPROC_HOME" gh issue create -R "$REPO" $LABEL_FLAGS $sec_label \
             --title "$title" --body-file "$body_file" 2>&1); then
    echo "  + filed: $title → $url"
    filed=$((filed + 1)); CREATED_NUMS+=("${url##*/}")
  else
    # retry once for the intermittent PAT 401
    sleep 2
    # shellcheck disable=SC2086
    if url=$(HOME="$SUBPROC_HOME" gh issue create -R "$REPO" $LABEL_FLAGS $sec_label \
               --title "$title" --body-file "$body_file" 2>&1); then
      echo "  + filed (retry): $title → $url"
      filed=$((filed + 1)); CREATED_NUMS+=("${url##*/}")
    else
      echo "  ⚠ failed to file '$title': $url"
    fi
  fi
done
shopt -u nullglob
echo "▶ Filed $filed issue(s)"

# Append the agent's filed/skipped summary to the report (deterministic).
if [[ -f "$DECIDE_DIR/_summary.md" ]]; then
  { echo ""; echo "---"; echo ""; cat "$DECIDE_DIR/_summary.md"; } >> "$REPORT_FILE"
  echo "▶ Filing summary appended to $REPORT_FILE"
fi

# ── Post-filing decoration (deterministic, not the agent) ─────────────────
# Collect this run's new issues (created since FILING_START_TS) once, then:
#   * set the issue TYPE        — ARGUS_ISSUE_TYPE in .env, default "Bug"
#                                 (org issue type; empty value disables)
#   * add to a Projects v2 board — ARGUS_GITHUB_PROJECT in .env (board title
#                                 under the repo owner; unset disables; needs
#                                 org-level 'Projects: read & write' on the PAT)
# NOTE: another board's auto-add workflow can still pull issues onto OTHER
# boards — that is GitHub-side config, not controllable from here.
ISSUE_TYPE_RAW="$(grep -E '^ARGUS_ISSUE_TYPE=' /opt/data/.env 2>/dev/null | tail -1 || true)"
if [[ -n "$ISSUE_TYPE_RAW" ]]; then
  ISSUE_TYPE="$(echo "$ISSUE_TYPE_RAW" | cut -d= -f2- | xargs)"   # may be set to empty to disable
else
  ISSUE_TYPE="Bug"
fi
GH_PROJECT="$(grep -E '^ARGUS_GITHUB_PROJECT=' /opt/data/.env 2>/dev/null | tail -1 | cut -d= -f2- || true)"

# Decorate exactly the issues we just created (numbers captured from the
# create output) — no timestamp re-query, so no race with GitHub's index.
if [[ ${#CREATED_NUMS[@]} -eq 0 ]]; then
  echo "▶ No issues created this run — skipping type/board decoration."
fi

if [[ ${#CREATED_NUMS[@]} -gt 0 ]]; then
  PROJECT_NUM=""
  if [[ -n "$GH_PROJECT" ]]; then
    OWNER="${REPO%%/*}"
    PROJECT_NUM="$(HOME="$SUBPROC_HOME" gh project list --owner "$OWNER" --limit 100 --format json 2>/dev/null \
      | ARGUS_PROJECT_TITLE="$GH_PROJECT" python3 -c "
import json, os, sys
want = os.environ['ARGUS_PROJECT_TITLE'].strip().lower()
try:
    projects = json.load(sys.stdin).get('projects', [])
except Exception:  # gh errored or printed nothing (e.g. token lacks Projects perm)
    projects = []
print(next((p['number'] for p in projects if p['title'].strip().lower() == want), ''))
" )" || PROJECT_NUM=""
    if [[ -z "$PROJECT_NUM" ]]; then echo "⚠ Project '$GH_PROJECT' not found under $OWNER (or token lacks org Projects read/write) — issues stay repo-only."; fi
  fi

  typed=0; added=0
  for num in "${CREATED_NUMS[@]}"; do
    issue_url="https://github.com/$REPO/issues/$num"
    # Extra labels applied here deterministically — the filing agent was given
    # the label flags in its prompt but has been seen dropping them.
    if [[ -n "$EXTRA_LABELS" ]]; then
      HOME="$SUBPROC_HOME" gh issue edit "$num" -R "$REPO" --add-label "$EXTRA_LABELS" >/dev/null 2>&1 \
        || echo "  ⚠ could not add extra labels to #$num"
    fi
    if [[ -n "$ISSUE_TYPE" ]]; then
      if HOME="$SUBPROC_HOME" gh api -X PATCH "repos/$REPO/issues/$num" -f "type=$ISSUE_TYPE" >/dev/null 2>&1; then
        typed=$((typed + 1))
      else
        echo "  ⚠ could not set type '$ISSUE_TYPE' on #$num (org issue types enabled?)"
      fi
    fi
    if [[ -n "$PROJECT_NUM" ]]; then
      if HOME="$SUBPROC_HOME" gh project item-add "$PROJECT_NUM" --owner "$OWNER" --url "$issue_url" >/dev/null 2>&1; then
        added=$((added + 1))
      else
        echo "  ⚠ could not add #$num to project '$GH_PROJECT'"
      fi
    fi
  done
  if [[ -n "$ISSUE_TYPE" ]]; then echo "▶ Set type '$ISSUE_TYPE' on $typed/${#CREATED_NUMS[@]} new issue(s)"; fi
  if [[ -n "$PROJECT_NUM" ]]; then echo "▶ Added $added/${#CREATED_NUMS[@]} new issue(s) to project '$GH_PROJECT' (#$PROJECT_NUM)"; fi
fi
