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

mkdir -p /opt/data/reports/screenshots /opt/data/qa-notes
REPORT_FILE="/opt/data/reports/${SKILL}-$(date +%Y%m%d-%H%M).md"
NOTES_FILE="/opt/data/qa-notes/remundo.md"

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
- Vary your testing between runs: prioritise areas, fields and edge cases your notes say are not covered yet, and use different test inputs than last time.

Process:
1. Log in using the credentials and login method in site-config
2. Navigate to the target page
3. Explore it as a real user would — understand what is there and what it does
4. Test it thoroughly: edit fields, submit forms, navigate between sections
5. Try edge cases: empty values, very long strings, invalid data types, boundary numbers, special characters
6. Reproduce any suspected bug once before reporting it, and screenshot it as described in web-qa-workflow

When finished — or as soon as you are running low on turns:
- Write your bug report to ${REPORT_FILE} with write_file. For every bug: URL, steps to reproduce, expected vs actual behaviour, severity.
- Update ${NOTES_FILE}: what you covered this run, what is still untested, site quirks you learned.
- Print the report as your final message." \
  $PROVIDER_FLAGS

echo ""
if [ -f "$REPORT_FILE" ]; then
  echo "▶ Report written to $REPORT_FILE"
else
  echo "▶ No report file was written this run (expected $REPORT_FILE)"
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
