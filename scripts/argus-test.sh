#!/usr/bin/env bash
# argus-test — run a Remundo QA skill end-to-end
#
# Usage:
#   argus-test <skill-name> [--local] [--max-turns N]
#
# Examples:
#   argus-test main-terms
#   argus-test main-terms --local
#   argus-test hire-worker-wizard --local --max-turns 200
#
# Flags:
#   --local        Use local Ollama model (qwen3.5:35b) instead of default (gpt-4.1)
#   --max-turns N  Override the default turn limit (default: 150)
#
# The script runs two argus chat calls:
#   1. Load the skill, log in, navigate to the page
#   2. Auto-resume and execute the full test pass, then write the report

set -euo pipefail

SKILL=""
MAX_TURNS=150
PROVIDER_FLAGS=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)
      PROVIDER_FLAGS="--provider local -m qwen3.5:35b"
      shift ;;
    --max-turns)
      MAX_TURNS="$2"
      shift 2 ;;
    -*)
      echo "Unknown flag: $1"
      echo "Usage: argus-test <skill-name> [--local] [--max-turns N]"
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
  ls /opt/data/skills/qa/remundo/ 2>/dev/null || echo "  (none found)"
  echo ""
  echo "Flags:"
  echo "  --local          Use local Ollama model (qwen3.5:35b)"
  echo "  --max-turns N    Override turn limit (default: 150)"
  exit 1
fi

source /opt/hermes/.venv/bin/activate

MODEL_LABEL="${PROVIDER_FLAGS:+qwen3.5:35b (local)}"
MODEL_LABEL="${MODEL_LABEL:-gpt-4.1 (openai)}"

# If --local, verify Ollama is reachable before wasting turns
if [[ -n "$PROVIDER_FLAGS" ]]; then
  echo "▶ Checking Ollama connectivity at localhost:11434..."
  if ! curl -sf --max-time 3 http://localhost:11434/api/tags > /dev/null 2>&1; then
    echo ""
    echo "✗ Ollama is not reachable. Start it with:"
    echo ""
    echo "    OLLAMA_HOST=0.0.0.0 ollama serve &"
    echo ""
    echo "  Then re-run: argus-test ${SKILL} --local"
    exit 1
  fi
  echo "  ✓ Ollama is up"
  echo ""
fi

echo "▶ Step 1: Loading skill '$SKILL' and navigating to page... [$MODEL_LABEL]"
# shellcheck disable=SC2086
argus chat -q "Read your ${SKILL} skill and follow it." $PROVIDER_FLAGS

echo ""
echo "▶ Step 2: Running full test pass (max turns: ${MAX_TURNS})..."
# shellcheck disable=SC2086
argus chat -c -q "Continue testing all fields and tabs. When the full pass is complete write a single comprehensive report." --max-turns "$MAX_TURNS" $PROVIDER_FLAGS
