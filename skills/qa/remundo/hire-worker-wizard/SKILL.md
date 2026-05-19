---
name: hire-worker-wizard
title: Hire a Worker Wizard
description: Step-by-step walkthrough of the Remundo Hire a Worker wizard that creates an employment contract
summary: How to navigate the Hire a Worker wizard from worker type selection through to the Main Terms contract page.
---

# Hire a Worker Wizard

Navigate to the Hire a Worker section from the dashboard side nav. The wizard creates a contract
and ends on the Main Terms page.

See `svelte-spa-testing` for clicking Svelte nav buttons.
See `vaadin-web-components` for combobox interactions.

## Select Worker Type

- Radio buttons for Employee / Contractor — use `browser_click <ref>`
- Selecting Employee changes the URL to `.../create-eorinstance/employee`

## Step 1: Worker Details

- Fill: First Name, Last Name, Email (all required)
- Organisation pre-fills automatically
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

- ⚠️ Salary minimum is GBP 60,000 — lower values silently keep the button disabled with no error
- The Done button on this step reads "Generate Quote"
- After clicking: loading states for ~3-5s, then redirects to `/contract-quote/<uuid>`

## Main Terms Page (`/contract-quote/<uuid>`)

Final destination after the wizard. Contains:
- Tabs: Main Terms | Terms Validation | Work Order | Employment Agreement | Work Order Request
- Candidate details, salary, benefits, allowances, job details, protection clauses
- Actions: "Save & Close" and "Submit For Quotation"
