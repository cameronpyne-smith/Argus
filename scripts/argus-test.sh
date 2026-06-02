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
MAX_TURNS=150
PROVIDER_FLAGS=""

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

# shellcheck disable=SC2086
argus chat --max-turns "$MAX_TURNS" \
  -q "You are a QA engineer. Load your 'site-config', 'web-qa-workflow', and '${SKILL}' skills, then test the ${SKILL} page of the Remundo web app and find bugs.

1. Log in to the site using the credentials in site-config
2. Navigate to the target page
3. Explore the page as a real user would — look at what is there, understand what it does
4. Test it thoroughly: try editing fields, submitting forms, navigating between sections
5. Try edge cases: empty values, very long strings, invalid data types, boundary numbers
6. Look for anything broken, missing, or behaving unexpectedly
7. When you are done, write a clear report of every bug you found with: URL, steps to reproduce, expected vs actual behaviour, severity

Do not ask for direction — use your judgement to decide what to test and how." \
  $PROVIDER_FLAGS
