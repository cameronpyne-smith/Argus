---
name: expenses
title: Remundo Expenses Page QA
description: QA skill for the Remundo expenses page.
---

# Expenses Page

## Target URL

`https://dev.xml.remundo.com/expenses`

## What This Page Is

The expenses page allows workers to submit, view, and manage expense claims.
It may include a list of past expenses, a form to submit new expenses, and
status indicators (pending, approved, rejected).

## What to Test

- Can you view the expenses list?
- Can you submit a new expense claim? Try all fields — amounts, categories, dates, descriptions, attachments.
- Try edge cases: zero amounts, very large amounts, past dates, future dates, missing required fields.
- Do validation messages appear correctly for invalid inputs?
- Can you edit or delete an existing expense?
- Do status changes (approve/reject) behave as expected if available?
- Are there any console errors or failed network requests?

## What Is Not a Bug

- Slow network requests (dev environment)
- The Hermes agent UI overlay visible in screenshots — ignore it, it is not part of the site
