#!/usr/bin/env bash
# argus-test — run a Remundo QA skill end-to-end
#
# Usage:
#   argus-test <skill-name> [max-turns]
#
# Examples:
#   argus-test main-terms
#   argus-test hire-worker-wizard
#   argus-test main-terms 200
#
# The script runs two argus chat calls:
#   1. Load the skill, log in, navigate to the page
#   2. Auto-resume and execute the full test pass, then write the report

set -euo pipefail

SKILL="${1:-}"
MAX_TURNS="${2:-150}"

if [[ -z "$SKILL" ]]; then
  echo "Usage: argus-test <skill-name> [max-turns]"
  echo ""
  echo "Available QA skills:"
  ls /opt/data/skills/qa/remundo/ 2>/dev/null || echo "  (none found)"
  exit 1
fi

source /opt/hermes/.venv/bin/activate

echo "▶ Step 1: Loading skill '$SKILL' and navigating to page..."
argus chat -q "Read your ${SKILL} skill and follow it."

echo ""
echo "▶ Step 2: Running full test pass (max turns: ${MAX_TURNS})..."
argus chat -c -q "Continue testing all fields and tabs. When the full pass is complete write a single comprehensive report." --max-turns "$MAX_TURNS"
