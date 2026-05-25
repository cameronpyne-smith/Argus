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
CONTRACT_URL="https://dev.xml.remundo.com/organisations/f951a684-7816-4ba7-b080-cf347e7c5998/contract-quote/f492624f-418e-4766-9020-8da237286d8b"

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
echo ""
echo ""
echo "▶ Step 2: Running full test pass (max turns: ${MAX_TURNS})..."
# shellcheck disable=SC2086
argus chat -c -q "TESTING TASK: QA test of ${SKILL} page.

=== CRITICAL RULES ===
FORBIDDEN: browser_type, browser_fill, browser_vision
CONSOLE NOISE: Ignore all console output lines starting with Firebase/Warning/HTTP/Checking. Only use the final JSON your function returned.

=== ACTION 1: Verify page (2-3 turns max) ===
Run: browser_console: document.body.innerText.substring(0,300)
If page shows 'login', re-authenticate then navigate back to ${CONTRACT_URL}.
REPORT: confirm URL contains 'contract-quote' and page shows field names.

=== ACTION 2: List visible fields (1 turn) ===
Run: browser_console: document.body.innerText
REPORT: List every field name visible on the page.

=== ACTION 3: Test the 8 priority fields (2 turns per field = 16 turns) ===
For EACH of these fields: Start Date, Annual Salary, Notice Period - Organization, Notice Period - Employee, Nationality, Job Location, Work Schedule, Probation Period

Do EXACTLY these 2 steps per field (NO MORE):
  Step A - Click pencil icon:
  browser_console: (function(label){var el=[...document.querySelectorAll('*')].filter(function(e){var t=e.textContent.trim();return t===label||t.startsWith(label+' ');})[0];var row=el;for(var i=0;i<5&&row;i++){var icon=row.querySelector('vaadin-icon,svg,[data-icon]');if(icon){row.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));return 'clicked:'+row.tagName;}row=row.parentElement;}return 'not found';})('FIELD_LABEL_HERE')

  Step B - After 2 seconds sleep, check what dialog appeared:
  browser_console: (function(){var q=[document],r=[];while(q.length){var n=q.shift();try{n.querySelectorAll('vaadin-text-field,vaadin-date-picker,vaadin-combo-box,vaadin-number-field,vaadin-select,vaadin-text-area,vaadin-integer-field,input[type=text],input[type=date]').forEach(function(e){r.push(e.tagName.toLowerCase()+':'+(e.getAttribute('label')||e.type||''));});n.querySelectorAll('*').forEach(function(e){if(e.shadowRoot)q.push(e.shadowRoot);});}catch(x){}}return JSON.stringify(r);})()

  RECORD: field name | click result | inputs found (from Step B JSON)
  Then move to the NEXT field. Do NOT spend extra turns trying to interact with inputs.

=== ACTION 4: Write QA report immediately after testing all 8 fields ===
Format:
| Field | Dialog Opened | Input Type Found | Notes |
|-------|--------------|-----------------|-------|
(one row per field tested)

Then section:
BUGS FOUND:
- [severity] description, steps, expected vs actual

READ-ONLY FIELDS (expected): list any that showed 'not found' for pencil icon" --max-turns "$MAX_TURNS" $PROVIDER_FLAGS
