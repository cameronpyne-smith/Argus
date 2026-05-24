---
name: main-terms
title: Main Terms Page Testing
description: QA testing of the Main Terms contract configuration page after completing the Hire a Worker wizard
summary: How to test the Main Terms page — field editing, async save notifications, tab navigation, and edge case inputs.
---

# Main Terms Page Testing

The Main Terms page is reached after completing the Hire a Worker wizard. It is a
multi-tab form for configuring the employment contract. Changes save asynchronously.

## Required Skills — Read These First

Before starting, load all of these:

- `site-config` — login credentials, org UUID, base URL, and known good contract URL
- `svelte-spa-testing` — dispatchEvent pattern for Svelte buttons
- `vaadin-web-components` — combobox interaction pattern
- `web-qa-workflow` — async save handling, snapshot discipline, bug reporting

## ⚡ CRITICAL: Execute, Don't Narrate

Work through every field and tab making tool calls. When the full pass is complete,
write one report. Do not narrate what you are about to do — just do it.

- **FORBIDDEN: any text response before the final report** — no "Let me...", "I will...",
  "Now I...", "Let me try...", "Let me check...", "Let me snap..." or any other narration
- If you have a thought, act on it with a tool call — do not write it out
- No acknowledgement messages, no mid-test summaries, no check-ins
- If a field won't respond after 2 attempts, note it internally and move on immediately
- Do NOT use `browser_vision` for initial field discovery — use `browser_console`
  with `document.querySelectorAll` to enumerate inputs programmatically

## Getting to the Main Terms Page

**Do not run the wizard** — navigate directly to the known good contract URL from
`site-config`. The wizard has a known 401 bug that wastes turns. Use the fallback URL
immediately after login.

## Important: Snapshot May Return Empty

This page renders content outside the `#app` Svelte root, which causes `browser_snapshot`
to return an empty accessibility tree even when the page is fully loaded.

**If `browser_snapshot` returns empty or near-empty:**
1. Do NOT conclude the page is blank — the DOM has content
2. Run `browser_console: document.body.innerText.substring(0, 1000)` to confirm content is present
3. Use `browser_console` to find and interact with elements directly via `document.querySelector`
   rather than relying on snapshot refs
4. Use `browser_vision` (screenshot) to see the page visually and identify fields to interact with

## Discovering Fields Programmatically

After navigating to the contract page, use this `browser_console` call to enumerate
all editable inputs without needing a visual screenshot:

```javascript
[...document.querySelectorAll('input:not([disabled]), textarea:not([disabled]), vaadin-text-field, vaadin-date-picker, vaadin-combo-box, vaadin-integer-field, vaadin-number-field')]
  .map(el => ({tag: el.tagName, id: el.id, name: el.name||el.getAttribute('label')||'', value: el.value||el._value||''}))
```

This returns all interactive inputs. Use the `id` or `label` to identify fields, then
interact using `document.querySelector('#id')` or by Vaadin component tag.

## Page Structure

The page has 5 tabs across the top:

1. **Main Terms** — the primary tab with all editable contract fields (default view)
2. **Terms Validation** — validation summary for the contract
3. **Work Order** — work order details
4. **Employment Agreement** — the agreement document view
5. **Work Order Request** — request details

Primary actions at the top/bottom of the page:
- **Save & Close** — saves and returns to dashboard
- **Submit For Quotation** — submits the contract for pricing

## Async Save Pattern

Fields on this page save **asynchronously** — there is no explicit Save button per field.
After editing a field and moving focus away (clicking elsewhere or tabbing out), the app
sends a request and shows a notification when the save completes.

**Always wait for the save notification before verifying a change persisted:**

1. Edit a field
2. Click elsewhere on the page to trigger the save (blur the field)
3. Wait up to 5 seconds for a success notification (toast/snackbar)
4. Re-snapshot and confirm the field shows the saved value

**If no notification appears within 5 seconds:** check the browser console for errors.
Absence of notification is itself a potential bug.

**After a save, always re-read the field** to confirm the persisted value matches what
you entered — silent data truncation or transformation is a common bug type here.

## Testing Each Field

### What to test on every editable field

Work through these inputs in order — stop at the first that reveals a bug, note it, then
continue with the next field:

1. **Valid input** — enter a realistic value, blur, wait for save notification, confirm value persisted
2. **Boundary values** — minimum and maximum where applicable (e.g. salary: try 0, try 59999, try 60000, try 999999)
3. **Empty / clear** — delete the value entirely, blur, check whether the field is required (should show validation) or optional (should accept empty)
4. **Oversized input** — paste a very long string (200+ characters) into text fields — check for truncation without feedback, UI breakage, or server errors
5. **Special characters** — try `<script>alert(1)</script>`, `"double quotes"`, `O'Brien` (apostrophe), `100%`, `£50,000` in numeric fields
6. **Negative numbers** — in any numeric field (salary, days, percentages), try `-1`
7. **Wrong type** — type letters into a numeric field; type numbers into a name field

### Fields known to exist on Main Terms tab

Based on previous exploration — **re-snapshot to get current field list** as the UI may have changed:

- **Candidate name / email** — read-only (set during wizard); skip if not editable
- **Annual Salary** — likely read-only (set during wizard); if uneditable after 2 tries, skip it and note it
- **Currency** — Vaadin combobox; test changing to a non-GBP currency and saving
- **Start Date** — date picker; test past dates, far-future dates
- **Employment type** — read-only (set during wizard); skip if not editable
- **Job Title** — text or combobox; test long strings, special chars
- **Benefits / Allowances** — if editable, test adding/removing items
- **Probation period** — numeric (days/months); test 0, negative, very large values
- **Notice period** — numeric; same edge cases as probation

**Read-only fields are NOT bugs** — wizard-set values (salary, employment type, candidate
details) are expected to be locked on this page. Note them as "read-only as expected" and
move on immediately.

## Tab Navigation

Click each tab and verify:
1. The tab becomes active (URL may change or content switches)
2. The expected content loads — snapshot to confirm it is not blank
3. There are no JS console errors on tab switch

**Terms Validation tab:** this tab may show validation errors for the current contract
state. A page that is entirely empty here is suspicious — check console for errors.

## Known Working Patterns for This Page

### Editing a Vaadin text/number field

DO NOT call `.click()` on the outer vaadin element — it hits the shadow host, not the
input. Use Shadow DOM access:

```javascript
(function(selector, newValue) {
  const host = document.querySelector(selector);
  if (!host) return 'NOT FOUND';
  const input = host.shadowRoot.querySelector('input');
  if (!input) return 'NO INPUT';
  input.focus(); input.select();
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
  setter.call(input, newValue);
  input.dispatchEvent(new Event('input',  {bubbles: true}));
  input.dispatchEvent(new Event('change', {bubbles: true}));
  input.dispatchEvent(new Event('blur',   {bubbles: true}));
  return 'SET: ' + input.value;
})('vaadin-text-field#field-id', 'new value');
```

### Finding the right selector

```javascript
[...document.querySelectorAll('vaadin-text-field,vaadin-integer-field,vaadin-number-field,vaadin-text-area,vaadin-combo-box,vaadin-date-picker')]
  .map(el => ({tag: el.tagName, id: el.id, label: el.getAttribute('label')||'', value: el.value||'', readonly: el.readonly||false}))
```

Use the `id` from this output in the Shadow DOM setter above.

### Vaadin Comboboxes on This Page

Currency and potentially other fields use Vaadin comboboxes. After typing to filter,
click the item via dispatchEvent (see `vaadin-web-components` skill):

## Svelte Buttons

Save & Close and Submit For Quotation are likely Svelte component handlers.
If `browser_click` silently does nothing, use the `svelte-spa-testing` dispatchEvent
pattern. Verify by checking the URL changes or a notification appears.

## Edge Cases Specific to This Page

- **Submit For Quotation with missing required fields** — clear a required field, try to
  submit, expect a validation error. If submission succeeds with invalid data, that is a
  critical bug.
- **Concurrent edit** — not testable in automation, but note if the page has any optimistic
  locking or conflict detection UI.
- **Navigate away with unsaved changes** — if async saves require a blur, quickly navigate
  away immediately after typing (before blurring). Does the change get saved or lost? Is
  there a warning?
- **Salary below minimum after currency change** — change currency to one with a lower
  salary minimum, enter a value valid for that currency but not for GBP, then switch back
  to GBP. Does the validation re-evaluate?

## What Counts as a Bug Here

- Field accepts and saves clearly invalid data (negative salary, XSS string, etc.)
- Save notification never appears after editing a field
- Saved value differs from entered value (silent truncation or transformation)
- Console errors on tab switch
- Blank tab content with no loading indicator
- Submit For Quotation succeeds with invalid/incomplete data
- No validation message when a required field is cleared

## What is NOT a Bug

- Async saves that take 2-3 seconds — this is expected behaviour
- Read-only fields that cannot be edited — these are intentional
- Tabs that load slightly slowly — wait for networkidle before concluding blank

## Running the Full Test

Work through all fields and tabs without stopping. When the full pass is complete,
produce a single report listing:

1. Each field/section tested
2. The edge cases tried
3. Any bugs found (with URL, steps to reproduce, expected vs actual, severity)
4. Any section skipped and why

Do not stop mid-test to ask for direction — complete the full pass, then report.
