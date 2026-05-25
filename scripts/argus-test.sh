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
echo ""
echo "▶ Step 2: Running field tests (max turns: ${MAX_TURNS})..."
# shellcheck disable=SC2086
argus chat -c -q "TESTING TASK: QA test of ${SKILL} page.

RULES: No browser_type/browser_fill/browser_vision. Ignore console log noise (Firebase/HTTP lines). Only use the final JSON your function returned.

STEP 1: Verify page
browser_console: document.body.innerText.substring(0,200)
Confirm URL contains contract-quote. If shows login: run browser_console: ${LOGIN_JS} then sleep 5 then browser_navigate ${CONTRACT_URL} then sleep 3.

STEP 2: Execute these field tests IN ORDER. For each field: run the click, sleep 2, run the pierce, record the result. Do NOT deviate from these steps.

FIELD 1: Start Date
  Turn 1: browser_console: (function(){var el=[...document.querySelectorAll('*')].filter(function(e){var t=e.textContent.trim();return t==='Start Date'||t.startsWith('Start Date ');}).pop();var row=el;for(var i=0;i<6&&row;i++){if(row.querySelector('vaadin-icon')){row.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));return 'clicked:'+row.tagName+':'+row.textContent.trim().substring(0,30);}row=row.parentElement;}return 'not found:Start Date';})()
  Turn 2: terminal sleep 2
  Turn 2b: browser_console: (function(){var q=[document],r=[];while(q.length){var n=q.shift();try{n.querySelectorAll('vaadin-text-field,vaadin-date-picker,vaadin-combo-box,vaadin-number-field,vaadin-select,vaadin-text-area,vaadin-integer-field').forEach(function(e){r.push(e.tagName.toLowerCase()+':'+(e.getAttribute('label')||''));});n.querySelectorAll('*').forEach(function(e){if(e.shadowRoot)q.push(e.shadowRoot);});}catch(x){}}return JSON.stringify(r);})()
  Record: "Start Date | [click result] | [inputs JSON]" 

FIELD 2: Annual Salary
  Turn 3: browser_console: (function(){var el=[...document.querySelectorAll('*')].filter(function(e){var t=e.textContent.trim();return t==='Annual Salary'||t.startsWith('Annual Salary ');}).pop();var row=el;for(var i=0;i<6&&row;i++){if(row.querySelector('vaadin-icon')){row.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));return 'clicked:'+row.tagName+':'+row.textContent.trim().substring(0,30);}row=row.parentElement;}return 'not found:Annual Salary';})()
  Turn 4: terminal sleep 2
  Turn 4b: browser_console: (function(){var q=[document],r=[];while(q.length){var n=q.shift();try{n.querySelectorAll('vaadin-text-field,vaadin-date-picker,vaadin-combo-box,vaadin-number-field,vaadin-select,vaadin-text-area,vaadin-integer-field').forEach(function(e){r.push(e.tagName.toLowerCase()+':'+(e.getAttribute('label')||''));});n.querySelectorAll('*').forEach(function(e){if(e.shadowRoot)q.push(e.shadowRoot);});}catch(x){}}return JSON.stringify(r);})()
  Record: "Annual Salary | [click result] | [inputs JSON]" 

FIELD 3: Notice Period
  Turn 5: browser_console: (function(){var el=[...document.querySelectorAll('*')].filter(function(e){var t=e.textContent.trim();return t==='Notice Period'||t.startsWith('Notice Period ');}).pop();var row=el;for(var i=0;i<6&&row;i++){if(row.querySelector('vaadin-icon')){row.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));return 'clicked:'+row.tagName+':'+row.textContent.trim().substring(0,30);}row=row.parentElement;}return 'not found:Notice Period';})()
  Turn 6: terminal sleep 2
  Turn 6b: browser_console: (function(){var q=[document],r=[];while(q.length){var n=q.shift();try{n.querySelectorAll('vaadin-text-field,vaadin-date-picker,vaadin-combo-box,vaadin-number-field,vaadin-select,vaadin-text-area,vaadin-integer-field').forEach(function(e){r.push(e.tagName.toLowerCase()+':'+(e.getAttribute('label')||''));});n.querySelectorAll('*').forEach(function(e){if(e.shadowRoot)q.push(e.shadowRoot);});}catch(x){}}return JSON.stringify(r);})()
  Record: "Notice Period | [click result] | [inputs JSON]" 

FIELD 4: Probation Period
  Turn 7: browser_console: (function(){var el=[...document.querySelectorAll('*')].filter(function(e){var t=e.textContent.trim();return t==='Probation Period'||t.startsWith('Probation Period ');}).pop();var row=el;for(var i=0;i<6&&row;i++){if(row.querySelector('vaadin-icon')){row.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));return 'clicked:'+row.tagName+':'+row.textContent.trim().substring(0,30);}row=row.parentElement;}return 'not found:Probation Period';})()
  Turn 8: terminal sleep 2
  Turn 8b: browser_console: (function(){var q=[document],r=[];while(q.length){var n=q.shift();try{n.querySelectorAll('vaadin-text-field,vaadin-date-picker,vaadin-combo-box,vaadin-number-field,vaadin-select,vaadin-text-area,vaadin-integer-field').forEach(function(e){r.push(e.tagName.toLowerCase()+':'+(e.getAttribute('label')||''));});n.querySelectorAll('*').forEach(function(e){if(e.shadowRoot)q.push(e.shadowRoot);});}catch(x){}}return JSON.stringify(r);})()
  Record: "Probation Period | [click result] | [inputs JSON]" 

FIELD 5: Nationality
  Turn 9: browser_console: (function(){var el=[...document.querySelectorAll('*')].filter(function(e){var t=e.textContent.trim();return t==='Nationality'||t.startsWith('Nationality ');}).pop();var row=el;for(var i=0;i<6&&row;i++){if(row.querySelector('vaadin-icon')){row.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));return 'clicked:'+row.tagName+':'+row.textContent.trim().substring(0,30);}row=row.parentElement;}return 'not found:Nationality';})()
  Turn 10: terminal sleep 2
  Turn 10b: browser_console: (function(){var q=[document],r=[];while(q.length){var n=q.shift();try{n.querySelectorAll('vaadin-text-field,vaadin-date-picker,vaadin-combo-box,vaadin-number-field,vaadin-select,vaadin-text-area,vaadin-integer-field').forEach(function(e){r.push(e.tagName.toLowerCase()+':'+(e.getAttribute('label')||''));});n.querySelectorAll('*').forEach(function(e){if(e.shadowRoot)q.push(e.shadowRoot);});}catch(x){}}return JSON.stringify(r);})()
  Record: "Nationality | [click result] | [inputs JSON]" 

FIELD 6: Job Location
  Turn 11: browser_console: (function(){var el=[...document.querySelectorAll('*')].filter(function(e){var t=e.textContent.trim();return t==='Job Location'||t.startsWith('Job Location ');}).pop();var row=el;for(var i=0;i<6&&row;i++){if(row.querySelector('vaadin-icon')){row.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));return 'clicked:'+row.tagName+':'+row.textContent.trim().substring(0,30);}row=row.parentElement;}return 'not found:Job Location';})()
  Turn 12: terminal sleep 2
  Turn 12b: browser_console: (function(){var q=[document],r=[];while(q.length){var n=q.shift();try{n.querySelectorAll('vaadin-text-field,vaadin-date-picker,vaadin-combo-box,vaadin-number-field,vaadin-select,vaadin-text-area,vaadin-integer-field').forEach(function(e){r.push(e.tagName.toLowerCase()+':'+(e.getAttribute('label')||''));});n.querySelectorAll('*').forEach(function(e){if(e.shadowRoot)q.push(e.shadowRoot);});}catch(x){}}return JSON.stringify(r);})()
  Record: "Job Location | [click result] | [inputs JSON]" 

FIELD 7: Work Schedule
  Turn 13: browser_console: (function(){var el=[...document.querySelectorAll('*')].filter(function(e){var t=e.textContent.trim();return t==='Work Schedule'||t.startsWith('Work Schedule ');}).pop();var row=el;for(var i=0;i<6&&row;i++){if(row.querySelector('vaadin-icon')){row.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));return 'clicked:'+row.tagName+':'+row.textContent.trim().substring(0,30);}row=row.parentElement;}return 'not found:Work Schedule';})()
  Turn 14: terminal sleep 2
  Turn 14b: browser_console: (function(){var q=[document],r=[];while(q.length){var n=q.shift();try{n.querySelectorAll('vaadin-text-field,vaadin-date-picker,vaadin-combo-box,vaadin-number-field,vaadin-select,vaadin-text-area,vaadin-integer-field').forEach(function(e){r.push(e.tagName.toLowerCase()+':'+(e.getAttribute('label')||''));});n.querySelectorAll('*').forEach(function(e){if(e.shadowRoot)q.push(e.shadowRoot);});}catch(x){}}return JSON.stringify(r);})()
  Record: "Work Schedule | [click result] | [inputs JSON]" 

FIELD 8: Holidays
  Turn 15: browser_console: (function(){var el=[...document.querySelectorAll('*')].filter(function(e){var t=e.textContent.trim();return t==='Holidays'||t.startsWith('Holidays ');}).pop();var row=el;for(var i=0;i<6&&row;i++){if(row.querySelector('vaadin-icon')){row.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));return 'clicked:'+row.tagName+':'+row.textContent.trim().substring(0,30);}row=row.parentElement;}return 'not found:Holidays';})()
  Turn 16: terminal sleep 2
  Turn 16b: browser_console: (function(){var q=[document],r=[];while(q.length){var n=q.shift();try{n.querySelectorAll('vaadin-text-field,vaadin-date-picker,vaadin-combo-box,vaadin-number-field,vaadin-select,vaadin-text-area,vaadin-integer-field').forEach(function(e){r.push(e.tagName.toLowerCase()+':'+(e.getAttribute('label')||''));});n.querySelectorAll('*').forEach(function(e){if(e.shadowRoot)q.push(e.shadowRoot);});}catch(x){}}return JSON.stringify(r);})()
  Record: "Holidays | [click result] | [inputs JSON]" 

STEP 3: Write QA report as a table:
| Field | Click Result | Inputs Found | Status |
|-------|-------------|--------------|--------|
(one row per field)

Then list any BUGS found based on unexpected results." --max-turns "$MAX_TURNS" $PROVIDER_FLAGS
