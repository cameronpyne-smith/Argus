#!/usr/bin/env bash
# argus-test — autonomous QA run against a target page
#
# Usage:
#   argus-test <skill-name> [--local] [--max-turns N]
#
# Examples:
#   argus-test main-terms
#   argus-test main-terms --local

set -euo pipefail

SKILL=""
MAX_TURNS=400
PROVIDER_FLAGS=""
# Issue filing default comes from ARGUS_FILE_ISSUES in /opt/data/.env;
# --issues / --no-issues override per run. Report is always written.
FILE_ISSUES="$(grep -E '^ARGUS_FILE_ISSUES=' /opt/data/.env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]')"
FILE_ISSUES="${FILE_ISSUES:-false}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)
      PROVIDER_FLAGS="--provider local -m qwen3.5:35b"
      shift ;;
    --max-turns)
      MAX_TURNS="$2"
      shift 2 ;;
    --issues)
      FILE_ISSUES=true
      shift ;;
    --no-issues)
      FILE_ISSUES=false
      shift ;;
    -*)
      echo "Unknown flag: $1"
      exit 1 ;;
    *)
      SKILL="$1"
      shift ;;
  esac
done

if [[ -z "$SKILL" ]]; then
  echo "Usage: argus-test <skill-name> [--local] [--max-turns N]"
  echo ""
  echo "Available QA skills:"
  ls /opt/data/skills/ 2>/dev/null || echo "  (none found)"
  exit 1
fi

source /opt/hermes/.venv/bin/activate

if [[ -n "$PROVIDER_FLAGS" ]]; then
  echo "▶ Checking Ollama connectivity..."
  if ! curl -sf --max-time 3 http://localhost:11434/api/tags > /dev/null 2>&1; then
    echo "✗ Ollama is not reachable. Start it with: OLLAMA_HOST=0.0.0.0 ollama serve &"
    exit 1
  fi
  echo "  ✓ Ollama is up"
  echo ""
fi

echo "▶ Running QA test for '$SKILL' (max turns: ${MAX_TURNS})..."
echo ""

STAMP="$(date +%Y%m%d-%H%M)"
REPORT_FILE="/opt/data/reports/${SKILL}-${STAMP}.md"
NOTES_FILE="/opt/data/qa-notes/remundo.md"
# Bugs are recorded incrementally as small per-bug files while context is
# fresh; the report is assembled from them deterministically after the run.
# A 331-call session once ended by FABRICATING its closing report ("files
# updated", "3 screenshots captured" — none existed). Never depend on a
# heavily-compressed model doing the bookkeeping at the very end.
PARTS_DIR="/opt/data/reports/parts/${SKILL}-${STAMP}"
mkdir -p /opt/data/reports/screenshots /opt/data/qa-notes "$PARTS_DIR"

# Toolsets are restricted to what a QA run needs: every extra toolset adds
# tool schemas to the fixed prompt prefix, which costs context and slows
# every single model call.
# shellcheck disable=SC2086
argus chat --max-turns "$MAX_TURNS" \
  -t browser,skills,file,terminal \
  -q "You are an autonomous QA engineer testing the ${SKILL} page of the Remundo web app.

Before you start:
- Load these skills with skill_view: 'site-config', 'web-qa-workflow', '${SKILL}'
- Read your notes from previous runs with read_file: ${NOTES_FILE} (may not exist yet)

Rules:
- Test through the browser UI only, like a real user. Never call the backend API directly, and never use credentials other than the ones in site-config.
- Do not ask for direction. If something does not work, try a different approach on your own.
- Never end your turn by announcing what you will do next — keep calling tools until the work is done. Your final message comes only after the summary file is written.
- The browser console is only for confirming a UI bug you already observed. Do not spend turns analysing console logs, network requests or backend endpoints on their own — your job is testing through the UI.
- Vary your testing between runs: prioritise areas, fields and edge cases your notes say are not covered yet, and use different test inputs than last time.

Process:
1. Log in using the credentials and login method in site-config
2. Navigate to the target page
3. Explore it as a real user would — understand what is there and what it does
4. Test it thoroughly: edit fields, submit forms, navigate between sections
5. Try edge cases: empty values, very long strings, invalid data types, boundary numbers, special characters
6. Reproduce any suspected bug once before reporting it
7. RECORD each confirmed bug immediately, while it is still on screen — do all three steps before testing anything else:
   a. Call browser_vision — its result contains a screenshot_path
   b. Run in terminal: cp <that screenshot_path> /opt/data/reports/screenshots/<short-bug-name>.png
   c. Save the bug with write_file to ${PARTS_DIR}/bug-<n>.md containing exactly:
      ## <short factual bug title>
      URL: <copied exactly from the browser, never from memory>
      Steps to reproduce: <numbered, from login>
      Expected behaviour: ...
      Actual behaviour: <what you observed>
      Severity: Critical / High / Medium / Low
      Screenshot: /opt/data/reports/screenshots/<short-bug-name>.png
   A bug that is not saved to a file does not exist. Never describe bugs only in chat.

When finished — or as soon as you are running low on turns:
- Write ${PARTS_DIR}/summary.md with write_file: what you covered this run, what is still untested.
- Update ${NOTES_FILE}: coverage, untested areas, site quirks you learned.
- Print a short list of the bugs you recorded as your final message." \
  $PROVIDER_FLAGS

echo ""
# Babysitter: a small model sometimes ends its turn early — asking a question
# or narrating next steps instead of acting. summary.md is the completion
# signal; until it exists, continue the SAME session with a corrective nudge.
NUDGES=0
while [[ ! -f "$PARTS_DIR/summary.md" && $NUDGES -lt 3 ]]; do
  NUDGES=$((NUDGES + 1))
  echo "▶ Session ended without finishing (no summary.md) — continuing session (nudge $NUDGES/3)..."
  # shellcheck disable=SC2086
  argus chat --continue --max-turns 150 \
    -t browser,skills,file,terminal \
    -q "You stopped before finishing, and nothing you found has been saved. Do not ask the user anything — you are autonomous. Continue testing the ${SKILL} page per your original instructions. Record every confirmed bug with write_file to ${PARTS_DIR}/bug-<n>.md (title, exact URL, steps, expected, actual, severity, Screenshot line). When done — or if you have already tested enough — write ${PARTS_DIR}/summary.md and update ${NOTES_FILE}." \
    $PROVIDER_FLAGS
  echo ""
done

# Assemble the report deterministically from the per-bug files. If the model
# wandered or died late in the run, every bug recorded up to that point still
# makes it into the report.
BUG_COUNT=0
if ls "$PARTS_DIR"/bug-*.md >/dev/null 2>&1; then
  {
    echo "# ${SKILL} QA report — $(date '+%Y-%m-%d %H:%M')"
    echo
    for p in "$PARTS_DIR"/bug-*.md; do
      cat "$p"
      echo
      echo "---"
      echo
    done
    if [ -f "$PARTS_DIR/summary.md" ]; then
      echo "## Session summary"
      echo
      cat "$PARTS_DIR/summary.md"
    fi
  } > "$REPORT_FILE"
  BUG_COUNT=$(ls "$PARTS_DIR"/bug-*.md | wc -l)
  echo "▶ Report assembled from $BUG_COUNT recorded bug(s): $REPORT_FILE"
else
  echo "▶ No bugs were recorded this run (no files in $PARTS_DIR)"
fi

# ── GitHub issue filing (separate filer session) ──────────────────────────
# Gated by ARGUS_FILE_ISSUES / --issues. The QA report above is the input;
# a fresh, small agent session reads it, dedupes against existing
# Argus-labeled issues, and files only reproduced bugs. GH_TOKEN is exported
# for this invocation only — the main QA agent's gh is unauthenticated.
if [[ "$FILE_ISSUES" == "true" && -f "$REPORT_FILE" ]]; then
  ARGUS_GITHUB_TOKEN="$(grep -E '^ARGUS_GITHUB_TOKEN=' /opt/data/.env 2>/dev/null | tail -1 | cut -d= -f2-)"
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
