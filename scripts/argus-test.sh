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
echo "▶ Step 2: Running full test pass (max turns: ${MAX_TURNS})..."
# Step 2 resumes the browser session from step 1. The browser is already on the contract page.
# Key insight: browser_click works on accordion section headers (via snapshot full refs) but NOT
# on field-edit rows (pencil icons) — those require dispatchEvent.
# shellcheck disable=SC2086
argus chat -c -q "TESTING TASK: QA test of ${SKILL} page.

=== CRITICAL RULES (violations will break the test) ===
FORBIDDEN: browser_type, browser_fill, browser_vision
FORBIDDEN: browser_click on any element that opens a form dialog (use dispatchEvent instead)
ALLOWED:   browser_console, browser_snapshot, browser_click (on accordion headers only), terminal, browser_wait
CONSOLE NOISE: browser_console returns app log lines (Firebase, Warning, HTTP) before the return value. IGNORE all lines except the last JSON/value returned by your function. Do NOT write a report about console log output.

=== ACTION 1: Verify page ===
Run: browser_console: document.body.innerText.substring(0,300)
Expected: text containing 'Main Terms'. If you see 'login' instead:
  - Run browser_console: ${LOGIN_JS}
  - terminal sleep 5
  - browser_navigate ${CONTRACT_URL}
  - terminal sleep 3
  - Run browser_console: document.body.innerText.substring(0,200) to confirm
STOP. Report what you see.

=== ACTION 2: Expand all accordion sections ===
Run this EXACT browser_console call (copy it verbatim, do not modify):
(function(){var els=document.querySelectorAll('[aria-expanded]');if(els.length>0){var r=[];[...els].forEach(function(e){e.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));r.push(e.textContent.trim().substring(0,25));});return JSON.stringify({method:'aria',clicked:r});}var names=['Job Details','Candidate','Billing','Insurance','Allowances','Incentives','Protection'];var clicked=[];names.forEach(function(name){var el=[...document.querySelectorAll('*')].find(function(e){var t=e.textContent.trim();if(!t.startsWith(name)||t.length>=80)return false;if(getComputedStyle(e).cursor!=='pointer')return false;var p=e;while(p){if(/^(NAV|HEADER|ASIDE|A)$/.test(p.tagName))return false;p=p.parentElement;}return true;});if(el){el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));clicked.push(name);}});return JSON.stringify({method:'text',clicked:clicked});})()
Then: terminal sleep 3
Report ONLY the JSON returned (ignore all other console output). This uses aria-expanded first, text-match as fallback. Either way, report what was clicked.

=== ACTION 3: Discover fields ===
Run this EXACT browser_console call (copy it verbatim):
(function pierce(sel,root,out){out=out||[];try{[...root.querySelectorAll(sel)].forEach(el=>out.push(el));[...root.querySelectorAll('*')].forEach(el=>{if(el.shadowRoot)pierce(sel,el.shadowRoot,out);});}catch(e){}return out;})('vaadin-text-field,vaadin-integer-field,vaadin-number-field,vaadin-text-area,vaadin-combo-box,vaadin-date-picker,vaadin-time-picker,vaadin-select,vaadin-checkbox',document).map(el=>({tag:el.tagName.toLowerCase(),id:el.id||'',label:el.getAttribute('label')||'',value:String(el.value!==undefined?el.value:''),readonly:el.readonly||false,disabled:el.disabled||false}))
Report: the FULL JSON array verbatim. If empty array [], run diagnostic: browser_console: document.querySelectorAll('vaadin-date-picker,vaadin-text-field').length and report that number.

=== ACTION 4: Test editable fields ===
For each NON-readonly, NON-disabled field from ACTION 3:
a) Click its edit row using this pattern (replace FIELD_LABEL with the field's label):
   browser_console: (function(label){var el=[...document.querySelectorAll('*')].find(function(e){return e.textContent.includes(label)&&getComputedStyle(e).cursor==='pointer'&&e.querySelectorAll('vaadin-icon,img').length>0;});if(el)el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));return el?'clicked:'+el.tagName:'not found';})('FIELD_LABEL')
b) terminal sleep 1
c) Check what appeared: browser_console: document.querySelectorAll('vaadin-overlay,vaadin-dialog-overlay,[slot=overlay],[role=dialog]').length
d) If overlay appeared: browser_console: document.querySelector('vaadin-overlay,[role=dialog]').innerText to see the form
e) Record: field name, whether dialog opened, what inputs were visible

=== ACTION 5: Write QA report ===
List ONLY findings from direct UI interaction (NOT console log analysis):
1. Fields tested: name, editable/readonly, dialog opened Y/N
2. Bugs found: URL, exact steps to reproduce, expected vs actual, severity Critical/High/Medium/Low
3. Fields confirmed read-only: list as expected behaviour
4. Skipped fields: why skipped" --max-turns "$MAX_TURNS" $PROVIDER_FLAGS
