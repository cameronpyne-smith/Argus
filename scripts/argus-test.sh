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
echo "▶ Step 2: Running full test pass (max turns: ${MAX_TURNS})..."
# ARCHITECTURE: Vaadin inputs only appear in the DOM when an edit dialog is open.
# Flow: verify page → read visible field list → click pencil icons → pierce dialog → interact → report
# shellcheck disable=SC2086
argus chat -c -q "TESTING TASK: QA test of ${SKILL} page.

=== CRITICAL RULES ===
FORBIDDEN: browser_type, browser_fill, browser_vision
FORBIDDEN: browser_click on edit-dialog elements (dispatchEvent only inside dialogs)
CONSOLE NOISE: browser_console output includes app log lines (Firebase, Warning, HTTP, Checking) BEFORE your return value. IGNORE those lines. Use ONLY the final JSON/value your function returned.

=== ACTION 1: Verify page ===
Run: browser_console: document.body.innerText.substring(0,500)
Expected: text containing 'Main Terms' and field names like 'Start Date', 'Salary'.
If you see 'login' instead, re-authenticate:
  browser_console: ${LOGIN_JS}
  terminal sleep 5
  browser_navigate ${CONTRACT_URL}
  terminal sleep 3
REPORT: the first 500 chars of page text you see.

=== ACTION 2: List all visible field names ===
Run: browser_console: document.body.innerText
From the output, identify ALL field names that appear on the page (look for label-like text before values: e.g. 'Start Date', 'Salary', 'Notice Period', 'Job Title', etc.)
REPORT: the complete list of field names visible on the page.

=== ACTION 3: Test each field by clicking its pencil/edit icon ===
NOTE: Vaadin form inputs ONLY appear in the DOM after an edit dialog is opened.
The pierce query must run AFTER clicking the pencil icon, not before.

For EACH field name from ACTION 2, repeat this sub-sequence:

  Step 3a - Click the pencil/edit icon for the field:
  browser_console: (function(label){var el=[...document.querySelectorAll('*')].filter(function(e){var t=e.textContent.trim();return t===label||t.startsWith(label+' ');})[0];var row=el;for(var i=0;i<5&&row;i++){var icon=row.querySelector('vaadin-icon,svg,[data-icon]');if(icon){row.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));return 'clicked row for: '+label;}row=row.parentElement;}return 'pencil not found for: '+label;})('FIELD_LABEL_HERE')

  Step 3b - Wait: terminal sleep 2

  Step 3c - Check for edit dialog inputs (stack-based shadow DOM search):
  browser_console: (function(){var q=[document],r=[];while(q.length){var n=q.shift();try{n.querySelectorAll('vaadin-text-field,vaadin-date-picker,vaadin-combo-box,vaadin-number-field,vaadin-select,vaadin-text-area,vaadin-integer-field').forEach(function(e){r.push(e.tagName.toLowerCase()+':'+(e.getAttribute('label')||''));});n.querySelectorAll('*').forEach(function(e){if(e.shadowRoot)q.push(e.shadowRoot);});}catch(x){}}return JSON.stringify(r);})()

  Step 3d - REPORT: field name, click result from 3a, inputs found from 3c.

  Step 3e - If inputs were found, interact with the FIRST one:
    For date-picker: browser_console: (function(){var e=document.querySelector('vaadin-date-picker');if(e){e.value='2099-12-31';e.dispatchEvent(new CustomEvent('value-changed',{detail:{value:'2099-12-31'},bubbles:true}));}return e?'date set to 2099-12-31':'not found';})()
    For text-field: browser_console: (function(){var e=document.querySelector('vaadin-text-field');var i=e&&e.shadowRoot&&e.shadowRoot.querySelector('input');if(i){Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value').set.call(i,'TEST');i.dispatchEvent(new Event('input',{bubbles:true}));}return i?'text field set':'not found';})()
    For combo-box: browser_console: (function(){var e=document.querySelector('vaadin-combo-box');if(e&&e.items&&e.items.length){e.value=e.items[e.items.length-1];e.dispatchEvent(new CustomEvent('value-changed',{bubbles:true}));}return e?'combo set to: '+(e.value||'?'):'not found';})()

  Step 3f - Close the dialog:
  browser_console: (function(){var b=[...document.querySelectorAll('button,vaadin-button')].find(function(b){var t=b.textContent.trim().toLowerCase();return t==='cancel'||t==='close';});if(b)b.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));return b?'closed':'no cancel btn - trying Escape';})()
  If no cancel button: browser_console: document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}))

  Step 3g - terminal sleep 1, then repeat for the next field.

Test these fields in priority order: Start Date, End Date, Salary, Notice Period, Job Title, any others visible.

=== ACTION 4: Write QA report ===
Report ONLY findings from direct UI interaction:
1. Fields tested: name, dialog opened Y/N, input type found, interaction result
2. Bugs: URL, steps to reproduce, expected vs actual, severity Critical/High/Medium/Low
3. Read-only fields: list as expected behaviour
4. Skipped fields: why" --max-turns "$MAX_TURNS" $PROVIDER_FLAGS
