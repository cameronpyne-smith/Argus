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
      PROVIDER_FLAGS="--provider local -m qwen3.5:35b"
      shift ;;
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

ARGUS_GITHUB_TOKEN="$(grep -E '^ARGUS_GITHUB_TOKEN=' /opt/data/.env 2>/dev/null | tail -1 | cut -d= -f2-)"
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

# shellcheck disable=SC2086
argus chat --max-turns 80 -t terminal,file \
  -q "You are filing QA bugs as GitHub issues in the repository ${REPO}. The gh CLI is already authenticated — just run gh commands in the terminal.

Step 1 — read the bug report at ${REPORT_FILE} with read_file.

Step 2 — fetch existing Argus issues for dedupe. Run:
gh issue list -R ${REPO} --label Argus --state all --limit 200 --json number,title,state

Step 3 — go through each bug in the report and decide:
- SKIP if it was not actually reproduced: no concrete reproduction steps with an observed actual result, or marked 'needs verification' / 'not tested'. These stay in the report only.
- SKIP if an OPEN issue from step 2 already describes the same bug (same page + same behaviour, even if worded differently). Note its #number.
- FILE it otherwise. If a CLOSED issue from step 2 describes the same bug, still file it and include a line 'Regression — previously fixed in #<number>' at the top of the body.

Step 4 — for each bug to file:
a. Write the issue body to /tmp/issue-<n>.md with write_file. The body is the bug's full section copied from the report — URL, steps to reproduce, expected behaviour, actual behaviour, severity — ending with the footer line:
   _Filed by Argus from ${REPORT_NAME} (${RUN_DATE})_
b. Create the issue:
gh issue create -R ${REPO} --label Argus --title \"<short factual title>\" --body-file /tmp/issue-<n>.md
   Titles are short, factual, no prefixes or tags, e.g.: Expense form saves with empty required Title field
   If the bug is security-related (XSS, injection, auth bypass), add: --label Security

Step 5 — write a filing summary to /tmp/argus-filed-issues.md with write_file (do NOT touch ${REPORT_FILE}): a '## Filed issues' heading and a list of every bug with either its new issue URL, the existing issue number it duplicates, or the reason it was skipped.

Finish by printing that same filed/skipped summary as your final message.

Rules: only create issues — never edit, close or comment on existing ones. Never file anything that is not in the report. Use URLs exactly as written in the report. gh is already authenticated — never run gh auth login, logout or status. If a gh command fails with 'HTTP 401', just run the exact same command again." \
  $PROVIDER_FLAGS

# The agent only writes its summary to /tmp — appending to the report is done
# here deterministically (an early agent once 'appended' by overwriting the
# whole report with just the new section).
SUMMARY=/tmp/argus-filed-issues.md
if [[ -f "$SUMMARY" ]]; then
  { echo ""; echo "---"; echo ""; cat "$SUMMARY"; } >> "$REPORT_FILE"
  rm -f "$SUMMARY"
  echo "▶ Filing summary appended to $REPORT_FILE"
fi
