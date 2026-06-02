---
name: main-terms
title: Main Terms — Contract Quote Editor
description: QA testing of the Main Terms contract configuration page.
---

# Main Terms Page

## What This Page Is

The Main Terms page is a multi-tab editor for configuring an employment contract quote.
It is reached after a "Hire a Worker" wizard or by navigating directly to a contract quote URL.

## Target URL

```
https://dev.xml.remundo.com/organisations/f951a684-7816-4ba7-b080-cf347e7c5998/contract-quote/f492624f-418e-4766-9020-8da237286d8b
```

## What the Page Does

- Displays contract details across several tabs (Main Terms, Terms Validation, Work Order, etc.)
- Many fields are editable inline — clicking a field opens an edit dialog or enables the field directly
- Changes save asynchronously — a toast notification appears when a save completes
- Some fields are read-only (set during the wizard) — this is expected behaviour

## What Matters to Test

- Can fields be opened for editing?
- Do edited values save correctly and persist after re-loading?
- Do fields validate input — e.g. reject negative salary, invalid dates, XSS strings?
- Does the save notification appear after every edit?
- Do all tabs load without errors?
- Does submitting the form with invalid/missing data show appropriate errors?

## What Is Not a Bug

- Fields that are read-only — some are intentionally locked after the wizard
- Async saves taking 2-3 seconds — this is expected
- Tabs that take a moment to load content
