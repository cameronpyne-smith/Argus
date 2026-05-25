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
# Step 1 has a hard 15-turn cap — login + navigate should need at most 5 turns.
# The login JS is embedded here so the model cannot misread the skill and use the wrong approach.
LOGIN_JS='(function(){var e=document.querySelector("input[type=email]");e.value="loxerot721@hilostar.com";e.dispatchEvent(new Event("input",{bubbles:true}));var p=document.querySelector("input[type=password]");p.value="passWord123";p.dispatchEvent(new Event("input",{bubbles:true}));setTimeout(function(){var btn=[...document.querySelectorAll("button")].find(b=>b.textContent.trim()==="Log in");btn.dispatchEvent(new MouseEvent("click",{bubbles:true,cancelable:true,view:window}));},500);})();'
CONTRACT_URL="https://dev.xml.remundo.com/organisations/f951a684-7816-4ba7-b080-cf347e7c5998/contract-quote/f492624f-418e-4766-9020-8da237286d8b?view=Active"

# shellcheck disable=SC2086
argus chat --max-turns 15 -q "Read your ${SKILL} skill. Then do EXACTLY these steps — no variations:
1. browser_navigate https://dev.xml.remundo.com/login
2. browser_console: ${LOGIN_JS}
3. Wait 5 seconds (browser_wait 5000 or similar), then snapshot and confirm URL contains /dashboard
4. If still on login, repeat step 2 once only
5. browser_navigate ${CONTRACT_URL}
6. Confirm page has loaded (snapshot or console check), then STOP — do NOT begin testing.
Never use browser_click or browser_type to log in." $PROVIDER_FLAGS

echo ""
echo "▶ Step 2: Running full test pass (max turns: ${MAX_TURNS})..."
# Step 2 embeds login JS, contract URL, shadow pierce JS, and explicit field interaction steps.
# shellcheck disable=SC2086
argus chat -c -q "You are testing the ${SKILL} page at: ${CONTRACT_URL}

STEP A — Get on the right page:
1. Navigate to: ${CONTRACT_URL}
2. Wait 5 seconds (sleep 5) for the SPA to hydrate
3. Run: window.location.href — confirm it contains 'contract-quote'. If it shows 'login', you were redirected.
4. If redirected to login, run this browser_console EXACTLY:
${LOGIN_JS}
   Then sleep 5, then navigate back to the contract URL, then sleep 3 more seconds.
5. Verify with: document.body.innerText — it should contain 'Main Terms' and field names.
   IMPORTANT: browser_snapshot will only show 1 element on this page — that is normal. Do NOT use snapshot element count to judge whether the page loaded. Use innerText instead.

STEP B — Discover all fields (run this browser_console BEFORE touching anything):
(function pierce(sel,root,out){out=out||[];try{[...root.querySelectorAll(sel)].forEach(el=>out.push(el));[...root.querySelectorAll('*')].forEach(el=>{if(el.shadowRoot)pierce(sel,el.shadowRoot,out);});}catch(e){}return out;})('vaadin-text-field,vaadin-integer-field,vaadin-number-field,vaadin-text-area,vaadin-combo-box,vaadin-date-picker,vaadin-time-picker,vaadin-select,vaadin-checkbox',document).map(el=>({tag:el.tagName.toLowerCase(),id:el.id||'(no id)',label:el.getAttribute('label')||'',value:el.value!==undefined?el.value:el.checked,readonly:el.readonly||false,disabled:el.disabled||false}))
If the result is empty, expand each accordion section first (browser_click on the section headers) then re-run the query. Fields only render after their section is opened.
After clicking any field to open an edit overlay, also check for overlays: [...document.querySelectorAll('vaadin-date-picker-overlay,vaadin-dialog-overlay,vaadin-overlay')].map(el=>({tag:el.tagName.toLowerCase(),opened:el.opened||!el.hidden}))

STEP C — Test every field found in STEP B:
- For each non-readonly field: test valid input, empty, boundary values, special chars
- For date-pickers: set el.value = 'YYYY-MM-DD' via browser_console, dispatch value-changed
- For text fields: use nativeInputValueSetter + input/change/blur events via browser_console
- For combo-boxes: set el.opened=true, then click the matching vaadin-combo-box-item
- Click each tab (Main Terms, Terms Validation, Work Order, Employment Agreement) and verify it loads
- Click Save & Close and observe what happens

STEP D — Write the QA report listing:
1. Each field tested and what edge cases were tried
2. Any bugs found (URL, exact steps, expected vs actual, severity: Critical/High/Medium/Low)
3. Fields that are read-only — note them as expected, not bugs
4. Any tabs that failed to load

Do NOT report on browser console logs or API health. Only report on direct UI behaviour you observed." --max-turns "$MAX_TURNS" $PROVIDER_FLAGS
