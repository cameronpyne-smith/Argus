#!/usr/bin/env bash
# argus-test — autonomous QA run driven by a per-site coverage ledger.
#
# The ledger (qa-notes/<site>/) holds STATE, not history:
#   index.md     one line per area+persona: area | start-url | persona | last-tested
#                — maintained by THIS script, never by the agent
#   <area>.md    current facts/coverage for one area (~50 lines, model-maintained)
# History lives in /opt/data/reports/. The agent only ever sees the index's
# chosen slice: its one area file, copied into /opt/data/run/.
#
# Usage:
#   argus-test                      # pick the area most in need (never > oldest)
#   argus-test expenses             # focus a specific area
#   argus-test --focus expenses --persona default --local --issues
#   argus-test --discover --local   # map the site: fill the index, no testing
#
set -euo pipefail

SITE="remundo"
SITE_HOST="dev.xml.remundo.com"
SITE_DIR="/opt/data/qa-notes/${SITE}"
INDEX="$SITE_DIR/index.md"
RUN_DIR="/opt/data/run"

FOCUS=""
PERSONA="candidate"
# Sessions are deliberately SHORT (120 turns): the context compressor can
# no-op on long agentic sessions and pin them at the 32K ceiling; every
# babysitter continuation restarts with freshly compressed context (~10-20K),
# so many short sessions beat one long one. Override with --max-turns.
MAX_TURNS=120
PROVIDER_FLAGS=""
# Hard wall-clock cap per agent session. The context compressor can no-op on
# long sessions, pinning the run at the ceiling with multi-minute hung calls;
# timeout fires SIGINT (clean Hermes shutdown) so the post-run salvage still
# assembles and files whatever bugs were recorded. Override with SESSION_TIMEOUT.
SESSION_TIMEOUT="${SESSION_TIMEOUT:-2400}"
DISCOVER=false
# Issue filing default comes from ARGUS_FILE_ISSUES in /opt/data/.env;
# --issues / --no-issues override per run. Report is always written.
FILE_ISSUES="$(grep -E '^ARGUS_FILE_ISSUES=' /opt/data/.env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]' || true)"
FILE_ISSUES="${FILE_ISSUES:-false}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)
      PROVIDER_FLAGS="--provider local -m qwen3.6:35b"
      shift ;;
    --model)
      # local ollama model override, e.g. --model qwen3.6:35b
      PROVIDER_FLAGS="--provider local -m $2"
      shift 2 ;;
    --max-turns)
      MAX_TURNS="$2"; shift 2 ;;
    --focus)
      FOCUS="$2"; shift 2 ;;
    --persona)
      PERSONA="$2"; shift 2 ;;
    --discover)
      DISCOVER=true; shift ;;
    --issues)
      FILE_ISSUES=true; shift ;;
    --no-issues)
      FILE_ISSUES=false; shift ;;
    -*)
      echo "Unknown flag: $1"; exit 1 ;;
    *)
      FOCUS="$1"; shift ;;
  esac
done

source /opt/hermes/.venv/bin/activate

if [[ -n "$PROVIDER_FLAGS" ]]; then
  echo "▶ Checking Ollama connectivity..."
  if ! curl -sf --max-time 3 http://localhost:11434/api/tags > /dev/null 2>&1; then
    echo "✗ Ollama is not reachable. Start it with: OLLAMA_HOST=0.0.0.0 ollama serve &"
    exit 1
  fi
  echo "  ✓ Ollama is up"
fi

mkdir -p "$SITE_DIR" /opt/data/reports/screenshots /opt/data/reports/parts
if [[ ! -f "$INDEX" ]]; then
  {
    echo "# ${SITE} coverage index — maintained by argus-test. Agents must not edit this file."
    echo "# Format: area | start-url | persona | last-tested   (last-tested: YYYY-MM-DD or 'never')"
    echo "dashboard | https://${SITE_HOST}/dashboard | default | never"
  } > "$INDEX"
fi

# ── Area selection ─────────────────────────────────────────────────────────
# Deterministic, harness-side: never-tested areas first, then the stalest.
# The model is never asked to choose.
index_lookup_url() {  # $1 area
  awk -F'|' -v a="$1" -v p="$PERSONA" '
    /^#/ {next}
    { gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $3) }
    $1==a && $3==p { print $2; exit }' "$INDEX"
}

if [[ "$DISCOVER" == "true" ]]; then
  AREA="discovery"
elif [[ -n "$FOCUS" ]]; then
  AREA="$FOCUS"
else
  AREA="$(awk -F'|' -v p="$PERSONA" '
    /^#/ {next}
    NF>=4 {
      for (i=1;i<=4;i++) gsub(/^[ \t]+|[ \t]+$/, "", $i)
      if ($3!=p) next
      if ($4=="never" && first=="") first=$1
      if ($4!="never" && (bestd=="" || $4<bestd)) { best=$1; bestd=$4 }
    }
    END { if (first!="") print first; else print best }' "$INDEX")"
  if [[ -z "$AREA" ]]; then
    echo "✗ No areas in the index for persona '$PERSONA' — add one or use --focus."
    exit 1
  fi
fi

AREA_URL=""
NAV_LINE=""
if [[ "$DISCOVER" != "true" ]]; then
  AREA_URL="$(index_lookup_url "$AREA")"
  if [[ -n "$AREA_URL" ]]; then
    NAV_LINE="Navigate to ${AREA_URL}"
  else
    NAV_LINE="Find the '${AREA}' area starting from https://${SITE_HOST}/dashboard"
  fi
fi

STAMP="$(date +%Y%m%d-%H%M)"
REPORT_FILE="/opt/data/reports/${AREA}-${STAMP}.md"
ARCHIVE_DIR="/opt/data/reports/parts/${AREA}-${STAMP}"

# Login instructions are inlined VERBATIM into the goal prompt. Models keep
# improvising broken login JS (missing input-event dispatches) when asked to
# reproduce the snippet from a skill loaded many turns earlier — inline text
# in the protected first message gets copied faithfully.
LOGIN_JS="$(cat "/opt/data/skills/site-config/login-${PERSONA}.js" 2>/dev/null || true)"
MFA_JS="$(cat /opt/data/skills/site-config/mfa-skip.js 2>/dev/null || true)"
if [[ -n "$LOGIN_JS" ]]; then
  LOGIN_STEP="Log in: navigate to https://${SITE_HOST}/login, then run EXACTLY this JavaScript with browser_console — copy it character for character, never write your own login code:
${LOGIN_JS}
Wait 5 seconds and check the URL. If it is /mfa-setup, run this with browser_console:
${MFA_JS}
Confirm the URL is no longer /login or /mfa-setup before continuing. If login shows 'Email/password incorrect', re-run the exact same snippet once — do not try other credentials or login methods."
else
  LOGIN_STEP="Log in as persona '${PERSONA}' using the credentials and login method in site-config"
fi

# ── Run dir: ALL agent file IO happens in /opt/data/run — one short path the
# model can reliably retain under context compression.
rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR"
if [[ "$DISCOVER" == "true" ]]; then
  # Discovery gets the index (read-only copy) so its job is "find what is
  # missing from this list" — the one mode where the model sees the index.
  grep -v '^#' "$INDEX" | awk -F'|' -v p="$PERSONA" '
    { gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $3) }
    $3==p { print $1 " | " $2 }' > "$RUN_DIR/known-areas.md"
elif [[ -f "$SITE_DIR/$AREA.md" ]]; then
  cp "$SITE_DIR/$AREA.md" "$RUN_DIR/area.md"
else
  printf '# %s\n\nNo notes on this area yet — first visit. Explore and record what you find.\n' "$AREA" > "$RUN_DIR/area.md"
fi

if [[ "$DISCOVER" == "true" ]]; then
  echo "▶ Discovery run: site=${SITE} persona=${PERSONA} (max turns: ${MAX_TURNS})"
else
  echo "▶ QA run: site=${SITE} area=${AREA} persona=${PERSONA} (max turns: ${MAX_TURNS})"
fi
echo ""

# Toolsets are restricted to what a QA run needs: every extra toolset adds
# tool schemas to the fixed prompt prefix, which costs context and slows
# every single model call.
if [[ "$DISCOVER" == "true" ]]; then
  NUDGE_PROMPT="You stopped before finishing. Do not ask the user anything — you are autonomous. Continue mapping the site per your original instructions: walk every navigation surface, append one '<area-name> | <exact URL>' line per newly found area to /opt/data/run/new-areas.md, and when you have covered all navigation write /opt/data/run/summary.md listing what you mapped."
  # shellcheck disable=SC2086
  timeout --signal=INT --kill-after=30 "$SESSION_TIMEOUT" \
    argus chat --max-turns "$MAX_TURNS" \
    -t browser,skills,file,terminal \
    -q "You are mapping the ${SITE} web app so it can be QA-tested area by area later. You are logged in as persona '${PERSONA}'. Your job this run is DISCOVERY ONLY — find pages, do not test them.

Before you start:
- Load these skills with skill_view: 'site-config', 'web-qa-workflow'
- Read /opt/data/run/known-areas.md with read_file — the areas already known. You are looking for what is MISSING from that list.

Rules:
- READ-ONLY exploration: navigate and look, but never submit forms, never enter data, never change settings. Clicking navigation links, menus and tabs is fine.
- The ONLY valid site domain is https://${SITE_HOST} — if you remember any other domain, it is wrong.
- Do not ask for direction. Never end your turn by announcing what you will do next — your final message comes only after /opt/data/run/summary.md is written.
- Areas are KINDS of pages, not individual records: a list page that opens detail pages is two areas — the list, and the detail page recorded once with one example URL. Never record one entry per record/row/uuid.

Process:
1. ${LOGIN_STEP}
2. Start at https://${SITE_HOST}/dashboard and systematically work through EVERY navigation surface: side nav entries, top bar menus, user/profile menus, settings, tabs inside pages, footer links
3. For every kind of page you reach that is not in known-areas.md, append one line to /opt/data/run/new-areas.md by running this in the terminal (append with >>, NEVER write_file — rewriting loses earlier entries):
   echo '<short-kebab-area-name> | <exact URL from the browser>' >> /opt/data/run/new-areas.md
4. If a page is visibly broken when you open it (error screen, blank page, crash), record it as a bug to /opt/data/run/bug-<n>.md (title, exact URL, steps, expected, actual, severity, plus a screenshot via browser_vision and cp to /opt/data/reports/screenshots/<name>.png) — but do not go looking for bugs

When you have walked all navigation — or are running low on turns:
- Write /opt/data/run/summary.md with write_file: which navigation surfaces you covered and which you could not reach
- Print the list of newly discovered areas as your final message." \
    $PROVIDER_FLAGS || echo "⚠ agent session exited abnormally — continuing with post-run"
else
  NUDGE_PROMPT="You stopped before finishing. Do not ask the user anything — you are autonomous. Continue testing the '${AREA}' area per your original instructions. Record every confirmed bug with write_file to /opt/data/run/bug-<n>.md (title, exact URL, steps, expected, actual, severity, Screenshot line). When done — or if you have already tested enough — rewrite /opt/data/run/area.md (current facts and coverage, max 50 lines) and write /opt/data/run/summary.md."
  # shellcheck disable=SC2086
  timeout --signal=INT --kill-after=30 "$SESSION_TIMEOUT" \
    argus chat --max-turns "$MAX_TURNS" \
  -t browser,skills,file,terminal \
  -q "You are an autonomous QA engineer testing the '${AREA}' area of the ${SITE} web app, logged in as persona '${PERSONA}'.

Before you start:
- Load these skills with skill_view: 'site-config', 'web-qa-workflow'
- Read /opt/data/run/area.md with read_file — your notes on this area from previous runs: what it is, its quirks, what is covered and what is not

Rules:
- Test through the browser UI only, like a real user. Never call the backend API directly, and only use the persona '${PERSONA}' credentials from site-config.
- The ONLY valid site domain is https://${SITE_HOST} — if you remember any other domain, it is wrong.
- Do not ask for direction. If something does not work, try a different approach on your own.
- Never end your turn by announcing what you will do next — keep calling tools until the work is done. Your final message comes only after /opt/data/run/summary.md is written.
- The browser console is only for confirming a UI bug you already observed. Do not spend turns analysing console logs, network requests or backend endpoints on their own.
- Use browser_snapshot to read pages. Call browser_vision only to capture a bug screenshot or when the snapshot genuinely cannot show something visual — its output is huge and crowds out your context.
- Prioritise what area.md says is NOT covered yet, and use different test inputs than previous runs.

Process:
1. ${LOGIN_STEP}
2. ${NAV_LINE}
3. Explore it as a real user would — understand what is there and what it does
4. Test it thoroughly: edit fields, submit forms, navigate between sections
5. Try edge cases: empty values, very long strings, invalid data types, boundary numbers, special characters
6. Reproduce any suspected bug once before recording it
7. RECORD each confirmed bug immediately, while it is still on screen — all three steps before testing anything else:
   a. Call browser_vision — its result contains a screenshot_path
   b. Run in terminal: cp <that screenshot_path> /opt/data/reports/screenshots/<short-bug-name>.png
   c. Save the bug with write_file to /opt/data/run/bug-<n>.md containing exactly:
      ## <short factual bug title>
      URL: <copied exactly from the browser, never from memory>
      Steps to reproduce: <numbered, from login>
      Expected behaviour: ...
      Actual behaviour: <what you observed>
      Severity: Critical / High / Medium / Low
      Screenshot: /opt/data/reports/screenshots/<short-bug-name>.png
   The Screenshot line must repeat EXACTLY the same filename you used in the cp command in step b — never invent a different name for it.
   A bug that is not saved to a file does not exist. Never describe bugs only in chat.
8. If you notice pages or sections OUTSIDE '${AREA}' that your notes do not mention (new nav links, new features), record each by running in the terminal: echo '<area-name> | <exact URL from the browser>' >> /opt/data/run/new-areas.md — do not test them this run.

When finished — or as soon as you are running low on turns:
- Rewrite /opt/data/run/area.md with write_file: the CURRENT facts about this area — what exists, its quirks, what is now covered, what remains untested. Replace stale lines instead of appending. No dates, no run history. Maximum 50 lines.
- Write /opt/data/run/summary.md with write_file: what you did this run.
- Print a short list of the bugs you recorded as your final message." \
  $PROVIDER_FLAGS || echo "⚠ agent session exited abnormally — continuing with post-run"
fi

echo ""
# Babysitter: a small model sometimes ends its turn early — asking a question
# or narrating next steps instead of acting. summary.md is the completion
# signal; until it exists, continue the SAME session with a corrective nudge.
NUDGES=0
while [[ ! -f "$RUN_DIR/summary.md" && $NUDGES -lt 5 ]]; do
  NUDGES=$((NUDGES + 1))
  echo "▶ Session ended without finishing (no summary.md) — continuing session (nudge $NUDGES/5)..."
  # shellcheck disable=SC2086
  timeout --signal=INT --kill-after=30 "$SESSION_TIMEOUT" \
    argus chat --continue --max-turns 120 \
    -t browser,skills,file,terminal \
    -q "$NUDGE_PROMPT" \
    $PROVIDER_FLAGS || echo "⚠ agent session exited abnormally — continuing with post-run"
  echo ""
done

# ── Post-run hygiene (harness-owned, deterministic) ────────────────────────
# Any URL whose host looks like the site but is not EXACTLY the site host is a
# model hallucination (seen: dev.remundo.com, remundo.dev) — it once poisoned
# the notes and sent later runs to dead domains. Fix hosts, keep paths.
# NB: guard with if, not '[[ ]] &&' — under set -e a missing file would
# short-circuit to exit 1 and kill the whole post-run (happened once: bugs
# recorded but never assembled, index never stamped).
fix_hosts() {
  if [[ -f "$1" ]]; then
    sed -E -i "s#https?://[A-Za-z0-9.-]*${SITE}[A-Za-z0-9.-]*#https://${SITE_HOST}#g" "$1"
  fi
}
fix_hosts "$RUN_DIR/area.md"
fix_hosts "$RUN_DIR/new-areas.md"
for b in "$RUN_DIR"/bug-*.md; do
  [[ -f "$b" ]] || continue
  fix_hosts "$b"
done

# Write back the area notes (size-capped — the ledger holds state, not history).
if [[ -s "$RUN_DIR/area.md" ]]; then
  head -60 "$RUN_DIR/area.md" > "$SITE_DIR/$AREA.md"
fi

# Fold newly discovered areas into the index (validated, deduped).
if [[ -s "$RUN_DIR/new-areas.md" ]]; then
  while IFS='|' read -r raw_name raw_url _; do
    name="$(echo "$raw_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-' | sed 's/^-*//; s/-*$//')"
    url="$(echo "$raw_url" | tr -d '[:space:]')"
    url="${url%%\?*}"   # query strings are views, not areas
    [[ -n "$name" && "$url" == https://${SITE_HOST}/* ]] || continue
    # Dedupe on BOTH name and URL: discovery agents record the same page
    # under several names (hire-worker / create-worker / hire-a-worker-wizard
    # were all /create-eorinstance in one run).
    if ! awk -F'|' -v a="$name" -v u="$url" -v p="$PERSONA" '
         /^#/ {next}
         { gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $3) }
         $3==p { sub(/\?.*$/, "", $2); if ($1==a || $2==u) found=1 } END { exit !found }' "$INDEX"; then
      echo "$name | $url | $PERSONA | never" >> "$INDEX"
      echo "▶ New area discovered: $name ($url)"
    fi
  done < "$RUN_DIR/new-areas.md"
fi

# Drift guard: the model has tested a different page than asked before (a
# 'dashboard' run once spent itself on /expenses/new). If bugs were recorded
# and they all sit under ANOTHER known area's URL while none sit under this
# area's, don't stamp — the area wasn't actually tested.
DRIFTED=false
if [[ "$DISCOVER" != "true" && -n "$AREA_URL" ]] && ls "$RUN_DIR"/bug-*.md >/dev/null 2>&1; then
  AREA_PATH="${AREA_URL#https://${SITE_HOST}}"
  BUG_URLS="$(grep -h "^URL:" "$RUN_DIR"/bug-*.md 2>/dev/null | sed 's/^URL:[[:space:]]*//')"
  if [[ -n "$BUG_URLS" && -n "$AREA_PATH" && "$AREA_PATH" != "/" ]]; then
    hits_here=0; hits_other=0
    while IFS= read -r u; do
      if [[ "$u" == "https://${SITE_HOST}${AREA_PATH}"* ]]; then
        hits_here=$((hits_here + 1))
      else
        # does it sit under a DIFFERENT known area of this persona?
        if awk -F'|' -v u="$u" -v p="$PERSONA" -v me="$AREA" -v host="https://${SITE_HOST}" '
             /^#/ {next}
             { for (i=1;i<=3;i++) gsub(/^[ \t]+|[ \t]+$/, "", $i) }
             $3==p && $1!=me && $2!=host"/dashboard" && index(u, $2)==1 { found=1 }
             END { exit !found }' "$INDEX"; then
          hits_other=$((hits_other + 1))
        fi
      fi
    done <<< "$BUG_URLS"
    if [[ $hits_here -eq 0 && $hits_other -gt 0 ]]; then
      DRIFTED=true
      echo "⚠ Drift detected: recorded bugs are under other areas' URLs, none under '${AREA}' — not stamping the index."
    fi
  fi
fi

# Stamp the tested area in the index. Discovery runs do NOT stamp anything —
# mapped is not tested; discovered areas stay 'never' so test runs pick them up.
TODAY="$(date +%F)"
if [[ "$DISCOVER" == "true" || "$DRIFTED" == "true" ]]; then
  :
elif awk -F'|' -v a="$AREA" -v p="$PERSONA" '
     /^#/ {next}
     { gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $3) }
     $1==a && $3==p { found=1 } END { exit !found }' "$INDEX"; then
  awk -F'|' -v a="$AREA" -v p="$PERSONA" -v d="$TODAY" '
    /^#/ { print; next }
    {
      o1=$1; o3=$3
      gsub(/^[ \t]+|[ \t]+$/, "", o1); gsub(/^[ \t]+|[ \t]+$/, "", o3)
      if (o1==a && o3==p) {
        gsub(/^[ \t]+|[ \t]+$/, "", $2)
        print o1 " | " $2 " | " o3 " | " d
      } else print
    }' "$INDEX" > "$INDEX.tmp" && mv "$INDEX.tmp" "$INDEX"
else
  echo "$AREA | ${AREA_URL:-https://${SITE_HOST}/dashboard} | $PERSONA | $TODAY" >> "$INDEX"
fi

# ── Assemble the report from the per-bug files ─────────────────────────────
# If the model wandered or died late in the run, every bug recorded up to that
# point still makes it into the report.
BUG_COUNT=0
if ls "$RUN_DIR"/bug-*.md >/dev/null 2>&1; then
  {
    echo "# ${SITE} ${AREA} QA report — $(date '+%Y-%m-%d %H:%M') (persona: ${PERSONA})"
    echo
    for p in "$RUN_DIR"/bug-*.md; do
      cat "$p"
      echo
      echo "---"
      echo
    done
    if [ -f "$RUN_DIR/summary.md" ]; then
      echo "## Session summary"
      echo
      cat "$RUN_DIR/summary.md"
    fi
  } > "$REPORT_FILE"
  BUG_COUNT=$(ls "$RUN_DIR"/bug-*.md | wc -l)
  echo "▶ Report assembled from $BUG_COUNT recorded bug(s): $REPORT_FILE"
else
  echo "▶ No bugs were recorded this run"
fi

# Archive the run dir alongside the reports.
mkdir -p "$(dirname "$ARCHIVE_DIR")"
mv "$RUN_DIR" "$ARCHIVE_DIR" 2>/dev/null || true

# ── GitHub issue filing (separate filer session) ──────────────────────────
# Gated by ARGUS_FILE_ISSUES / --issues. The QA report above is the input;
# a fresh, small agent session reads it, dedupes against existing
# Argus-labeled issues, and files only reproduced bugs.
if [[ "$FILE_ISSUES" == "true" && -f "$REPORT_FILE" ]]; then
  ARGUS_GITHUB_TOKEN="$(grep -E '^ARGUS_GITHUB_TOKEN=' /opt/data/.env 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  if [[ -z "$ARGUS_GITHUB_TOKEN" ]]; then
    echo "✗ Issue filing enabled but ARGUS_GITHUB_TOKEN is not set in /opt/data/.env — skipping."
  else
    echo "▶ Filing GitHub issues from $REPORT_FILE ..."
    argus-file-issues "$REPORT_FILE" $PROVIDER_FLAGS
  fi
elif [[ "$FILE_ISSUES" == "true" ]]; then
  echo "✗ Issue filing enabled but no report file exists — nothing to file."
else
  echo "▶ Issue filing is off (enable with --issues or ARGUS_FILE_ISSUES=true) — report only."
fi
