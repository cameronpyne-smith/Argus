---
name: hire-worker-wizard
title: Hire a Worker Wizard
description: Step-by-step walkthrough of the Remundo Hire a Worker wizard that creates an employment contract
summary: How to navigate the Hire a Worker wizard from worker type selection through to the Main Terms contract page.
---

# Hire a Worker Wizard

Navigate to the Hire a Worker section from the dashboard side nav. The wizard creates a contract
and ends on the Main Terms page.

## Required Skills — Read These First

Before starting, load all of these:

- `site-config` — login credentials, org UUID, base URL
- `svelte-spa-testing` — dispatchEvent pattern for Svelte buttons
- `vaadin-web-components` — combobox interaction pattern

## Advancing Through Steps (Done button)

The Done/Back wizard buttons are Svelte component handlers — `browser_click` silently does nothing.
You MUST use `browser_console` with this exact JS:

```javascript
// Advance to next step
(function(){
  const btn = document.querySelector('button[aria-label="Done"]');
  btn.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, view: window}));
})();
```

```javascript
// Go back
(function(){
  const btn = document.querySelector('button[aria-label="Back"]');
  btn.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, view: window}));
})();
```

After dispatching, wait ~1s then re-snapshot to confirm the URL/step changed.
If the button appears to click but nothing changes, the form has unfilled required fields — re-snapshot and look for fields still showing placeholder text.



- Radio buttons for Employee / Contractor — use `browser_click <ref>`
- Selecting Employee changes the URL to `.../create-eorinstance/employee`

## Step 1: Worker Details

- Fill: First Name, Last Name, Email (all required)
- Organisation pre-fills automatically
- **Phone dial code** — there is a Vaadin combobox for the dial code that MUST have a committed
  selection before the phone number field becomes enabled. Use the `vaadin-web-components` pattern:
  type a country name or dial code (e.g. "United Kingdom" or "+44") into the combobox, wait for
  the dropdown, then click the item via `dispatchEvent`. The phone number field is disabled until
  this combobox has a committed selection. If Done stays disabled, this is the most likely cause.
- Advance: `button[aria-label="Done"]` — use dispatchEvent (Svelte component)

## Step 2: Job Location

- Country: Vaadin combobox — type to filter, click item
- City/Region: disabled until Country is selected — fill Country first
- Advance: `button[aria-label="Done"]` — use dispatchEvent

## Step 3: Job Description

- Job Title: Vaadin combobox
- Job Description: standard text input
- Advance: `button[aria-label="Done"]` — use dispatchEvent

## Step 4: Work Schedule

- Standard hours pre-selected (Mon-Fri, 9-5)
- Advance: `button[aria-label="Done"]` — use dispatchEvent

## Step 5: Start Date & Salary

- Start Date: pre-filled to today, leave as-is
- Currency: pre-filled GBP, leave as-is
- Annual Salary: type `65000` (⚠️ minimum is GBP 60,000 — use 65000 to be safe; values at or below 60000 silently keep Done disabled with no error shown)
- Done button aria-label is `"Done"` even though its label reads "Generate Quote"
- After dispatching Done: **wait 3-5 seconds** for a loading state, then re-snapshot. The page will redirect to `/contract-quote/<uuid>`. Do not click again — just wait and snapshot.

## Main Terms Page (`/contract-quote/<uuid>`)

Final destination after the wizard. Contains:
- Tabs: Main Terms | Terms Validation | Work Order | Employment Agreement | Work Order Request
- Candidate details, salary, benefits, allowances, job details, protection clauses
- Actions: "Save & Close" and "Submit For Quotation"
