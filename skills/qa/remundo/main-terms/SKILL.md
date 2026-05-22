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

- `site-config` — login credentials, org UUID, base URL
- `hire-worker-wizard` — how to reach this page (complete the wizard first)
- `svelte-spa-testing` — dispatchEvent pattern for Svelte buttons
- `vaadin-web-components` — combobox interaction pattern
- `web-qa-workflow` — async save handling, snapshot discipline, bug reporting

**To get here:** complete the `hire-worker-wizard` skill first. The URL is:
`/organisations/<org-uuid>/contract-quote/<contract-uuid>`

**If the wizard fails to redirect** (e.g. gets stuck on the step navigator with no error),
do not stop — use the known good contract URL from your `site-config` skill and continue
testing from there. Note in your report that the wizard redirect failed.

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

- **Candidate name / email** — likely read-only; verify editing is blocked
- **Annual Salary** — numeric; minimum GBP 60,000 enforced (test the boundary: 59999 should fail or warn)
- **Currency** — Vaadin combobox; test changing to a non-GBP currency and saving
- **Start Date** — date picker; test past dates, far-future dates
- **Employment type** — likely read-only (set during wizard)
- **Job Title** — text or combobox; test long strings, special chars
- **Benefits / Allowances** — if editable, test adding/removing items
- **Probation period** — numeric (days/months); test 0, negative, very large values
- **Notice period** — numeric; same edge cases as probation

## Tab Navigation

Click each tab and verify:
1. The tab becomes active (URL may change or content switches)
2. The expected content loads — snapshot to confirm it is not blank
3. There are no JS console errors on tab switch

**Terms Validation tab:** this tab may show validation errors for the current contract
state. A page that is entirely empty here is suspicious — check console for errors.

## Vaadin Comboboxes on This Page

Currency and potentially other fields use Vaadin comboboxes. Use the
`vaadin-web-components` skill pattern: type to filter → snapshot to confirm dropdown →
dispatchEvent click item → wait for save notification.

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
