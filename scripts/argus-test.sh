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
echo ""
echo "▶ Step 2: Running field tests (max turns: ${MAX_TURNS})..."
# Store prompt in variable via heredoc to avoid bash newline splitting
read -r -d '' STEP2_PROMPT << 'PROMPT_EOF'
TESTING TASK: QA test of the main-terms page.

RULES: No browser_type/browser_fill/browser_vision. Ignore console log noise (Firebase/HTTP lines).

STEP 1 - Verify page
browser_console: document.body.innerText.substring(0,200)
Confirm URL contains contract-quote. If shows login: run browser_console: LOGIN_JS_PLACEHOLDER then sleep 5 then navigate back then sleep 3.

STEP 2 - Run these field tests IN EXACT ORDER, 3 steps each:

FIELD: Start Date
  Step A - browser_console: (function(){var el=[...document.querySelectorAll('*')].filter(function(e){var t=e.textContent.trim();return t==='Start Date'||t.startsWith('Start Date ');}).pop();var row=el;for(var i=0;i<6&&row;i++){if(row.querySelector('vaadin-icon')){row.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));return 'clicked:'+row.tagName+':'+row.textContent.trim().substring(0,30);}row=row.parentElement;}return 'not found:Start Date';})()
  Step B - terminal sleep 2
  Step C - browser_console: (function(){var q=[document],r=[];while(q.length){var n=q.shift();try{n.querySelectorAll('vaadin-text-field,vaadin-date-picker,vaadin-combo-box,vaadin-number-field,vaadin-select,vaadin-text-area,vaadin-integer-field').forEach(function(e){r.push(e.tagName.toLowerCase()+':'+(e.getAttribute('label')||''));});n.querySelectorAll('*').forEach(function(e){if(e.shadowRoot)q.push(e.shadowRoot);});}catch(x){}}return JSON.stringify(r);})()
  Record result for: Start Date

FIELD: Annual Salary
  Step A - browser_console: (function(){var el=[...document.querySelectorAll('*')].filter(function(e){var t=e.textContent.trim();return t==='Annual Salary'||t.startsWith('Annual Salary ');}).pop();var row=el;for(var i=0;i<6&&row;i++){if(row.querySelector('vaadin-icon')){row.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));return 'clicked:'+row.tagName+':'+row.textContent.trim().substring(0,30);}row=row.parentElement;}return 'not found:Annual Salary';})()
  Step B - terminal sleep 2
  Step C - browser_console: (function(){var q=[document],r=[];while(q.length){var n=q.shift();try{n.querySelectorAll('vaadin-text-field,vaadin-date-picker,vaadin-combo-box,vaadin-number-field,vaadin-select,vaadin-text-area,vaadin-integer-field').forEach(function(e){r.push(e.tagName.toLowerCase()+':'+(e.getAttribute('label')||''));});n.querySelectorAll('*').forEach(function(e){if(e.shadowRoot)q.push(e.shadowRoot);});}catch(x){}}return JSON.stringify(r);})()
  Record result for: Annual Salary

FIELD: Notice Period
  Step A - browser_console: (function(){var el=[...document.querySelectorAll('*')].filter(function(e){var t=e.textContent.trim();return t==='Notice Period'||t.startsWith('Notice Period ');}).pop();var row=el;for(var i=0;i<6&&row;i++){if(row.querySelector('vaadin-icon')){row.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));return 'clicked:'+row.tagName+':'+row.textContent.trim().substring(0,30);}row=row.parentElement;}return 'not found:Notice Period';})()
  Step B - terminal sleep 2
  Step C - browser_console: (function(){var q=[document],r=[];while(q.length){var n=q.shift();try{n.querySelectorAll('vaadin-text-field,vaadin-date-picker,vaadin-combo-box,vaadin-number-field,vaadin-select,vaadin-text-area,vaadin-integer-field').forEach(function(e){r.push(e.tagName.toLowerCase()+':'+(e.getAttribute('label')||''));});n.querySelectorAll('*').forEach(function(e){if(e.shadowRoot)q.push(e.shadowRoot);});}catch(x){}}return JSON.stringify(r);})()
  Record result for: Notice Period

FIELD: Probation Period
  Step A - browser_console: (function(){var el=[...document.querySelectorAll('*')].filter(function(e){var t=e.textContent.trim();return t==='Probation Period'||t.startsWith('Probation Period ');}).pop();var row=el;for(var i=0;i<6&&row;i++){if(row.querySelector('vaadin-icon')){row.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));return 'clicked:'+row.tagName+':'+row.textContent.trim().substring(0,30);}row=row.parentElement;}return 'not found:Probation Period';})()
  Step B - terminal sleep 2
  Step C - browser_console: (function(){var q=[document],r=[];while(q.length){var n=q.shift();try{n.querySelectorAll('vaadin-text-field,vaadin-date-picker,vaadin-combo-box,vaadin-number-field,vaadin-select,vaadin-text-area,vaadin-integer-field').forEach(function(e){r.push(e.tagName.toLowerCase()+':'+(e.getAttribute('label')||''));});n.querySelectorAll('*').forEach(function(e){if(e.shadowRoot)q.push(e.shadowRoot);});}catch(x){}}return JSON.stringify(r);})()
  Record result for: Probation Period

FIELD: Nationality
  Step A - browser_console: (function(){var el=[...document.querySelectorAll('*')].filter(function(e){var t=e.textContent.trim();return t==='Nationality'||t.startsWith('Nationality ');}).pop();var row=el;for(var i=0;i<6&&row;i++){if(row.querySelector('vaadin-icon')){row.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));return 'clicked:'+row.tagName+':'+row.textContent.trim().substring(0,30);}row=row.parentElement;}return 'not found:Nationality';})()
  Step B - terminal sleep 2
  Step C - browser_console: (function(){var q=[document],r=[];while(q.length){var n=q.shift();try{n.querySelectorAll('vaadin-text-field,vaadin-date-picker,vaadin-combo-box,vaadin-number-field,vaadin-select,vaadin-text-area,vaadin-integer-field').forEach(function(e){r.push(e.tagName.toLowerCase()+':'+(e.getAttribute('label')||''));});n.querySelectorAll('*').forEach(function(e){if(e.shadowRoot)q.push(e.shadowRoot);});}catch(x){}}return JSON.stringify(r);})()
  Record result for: Nationality

FIELD: Job Location
  Step A - browser_console: (function(){var el=[...document.querySelectorAll('*')].filter(function(e){var t=e.textContent.trim();return t==='Job Location'||t.startsWith('Job Location ');}).pop();var row=el;for(var i=0;i<6&&row;i++){if(row.querySelector('vaadin-icon')){row.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));return 'clicked:'+row.tagName+':'+row.textContent.trim().substring(0,30);}row=row.parentElement;}return 'not found:Job Location';})()
  Step B - terminal sleep 2
  Step C - browser_console: (function(){var q=[document],r=[];while(q.length){var n=q.shift();try{n.querySelectorAll('vaadin-text-field,vaadin-date-picker,vaadin-combo-box,vaadin-number-field,vaadin-select,vaadin-text-area,vaadin-integer-field').forEach(function(e){r.push(e.tagName.toLowerCase()+':'+(e.getAttribute('label')||''));});n.querySelectorAll('*').forEach(function(e){if(e.shadowRoot)q.push(e.shadowRoot);});}catch(x){}}return JSON.stringify(r);})()
  Record result for: Job Location

FIELD: Work Schedule
  Step A - browser_console: (function(){var el=[...document.querySelectorAll('*')].filter(function(e){var t=e.textContent.trim();return t==='Work Schedule'||t.startsWith('Work Schedule ');}).pop();var row=el;for(var i=0;i<6&&row;i++){if(row.querySelector('vaadin-icon')){row.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));return 'clicked:'+row.tagName+':'+row.textContent.trim().substring(0,30);}row=row.parentElement;}return 'not found:Work Schedule';})()
  Step B - terminal sleep 2
  Step C - browser_console: (function(){var q=[document],r=[];while(q.length){var n=q.shift();try{n.querySelectorAll('vaadin-text-field,vaadin-date-picker,vaadin-combo-box,vaadin-number-field,vaadin-select,vaadin-text-area,vaadin-integer-field').forEach(function(e){r.push(e.tagName.toLowerCase()+':'+(e.getAttribute('label')||''));});n.querySelectorAll('*').forEach(function(e){if(e.shadowRoot)q.push(e.shadowRoot);});}catch(x){}}return JSON.stringify(r);})()
  Record result for: Work Schedule

FIELD: Holidays
  Step A - browser_console: (function(){var el=[...document.querySelectorAll('*')].filter(function(e){var t=e.textContent.trim();return t==='Holidays'||t.startsWith('Holidays ');}).pop();var row=el;for(var i=0;i<6&&row;i++){if(row.querySelector('vaadin-icon')){row.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));return 'clicked:'+row.tagName+':'+row.textContent.trim().substring(0,30);}row=row.parentElement;}return 'not found:Holidays';})()
  Step B - terminal sleep 2
  Step C - browser_console: (function(){var q=[document],r=[];while(q.length){var n=q.shift();try{n.querySelectorAll('vaadin-text-field,vaadin-date-picker,vaadin-combo-box,vaadin-number-field,vaadin-select,vaadin-text-area,vaadin-integer-field').forEach(function(e){r.push(e.tagName.toLowerCase()+':'+(e.getAttribute('label')||''));});n.querySelectorAll('*').forEach(function(e){if(e.shadowRoot)q.push(e.shadowRoot);});}catch(x){}}return JSON.stringify(r);})()
  Record result for: Holidays

STEP 3 - Write report:
| Field | Click Result | Inputs Found |
|-------|-------------|--------------|
(one row per field above)
PROMPT_EOF

# Substitute login JS and provider flags
STEP2_PROMPT="${STEP2_PROMPT//LOGIN_JS_PLACEHOLDER/${LOGIN_JS}}"

# shellcheck disable=SC2086
argus chat -c -q "$STEP2_PROMPT" --max-turns "$MAX_TURNS" $PROVIDER_FLAGS
