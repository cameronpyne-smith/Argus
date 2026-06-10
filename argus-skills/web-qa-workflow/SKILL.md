---
name: web-qa-workflow
title: Web QA Testing Workflow
description: Core principles for autonomous browser-based QA testing.
summary: How to explore a web app, what counts as a bug, and how to report findings.
---

# Web QA Testing Workflow

## How to Approach a Page

1. **Explore first.** Take a snapshot or screenshot to understand what the page shows.
   Read it like a user would — what can you do here, what does it display?

2. **Test like a real user.** Click buttons, fill forms, navigate between sections.
   If a nav link is broken, that is a bug — don't route around it.

3. **Try things that should fail.** After confirming the happy path works, try:
   - Empty required fields
   - Values that are clearly invalid (negative salary, letters in a number field)
   - Very long strings (200+ characters)
   - Special characters: `<script>alert(1)</script>`, `O'Brien`, `£50,000`, `"quoted"`
   - Boundary values (0, -1, maximum allowed)

4. **Re-snapshot after every action.** Confirm what actually happened before drawing conclusions.

5. **Exhaust alternatives before concluding something is broken.** If one approach fails, try another.
   A click that does nothing is worth retrying with a different method before reporting it.

## Browser Console Rules

- **Always wrap `browser_console` JavaScript in an IIFE**: `(() => { const btn = ...; return btn?.textContent })()`.
  Consecutive evals share one JS scope — a bare `const btn = ...` will fail next time with
  "Identifier 'btn' has already been declared".
- To wait for an async UI update from inside the page: `await new Promise(r => setTimeout(r, 2000))`
  (or use the terminal: `sleep 2`), then re-snapshot.
- Use the console to *inspect* and to work around known SPA event quirks — not to bypass the UI.
  Submitting data by calling the backend API directly is never a valid test.

## Credentials

Only ever use the credentials provided in the site-config skill. Never invent, guess,
or reuse credentials from anywhere else, and never try to register new accounts unless
the task explicitly asks for it.

## What Counts as a Bug

- A field accepts and saves clearly invalid data (XSS string, negative salary)
- A save silently fails — no confirmation, no error, data not persisted
- A required field can be cleared and submitted without validation
- A page section is blank with no loading indicator and no error message
- A navigation link does not navigate
- The browser console shows an unhandled JS error during normal use
- Submitted value differs from what was entered (silent truncation or transformation)

## What Is Not a Bug

- Fields that are read-only — some are intentionally locked
- Async operations that take 2-3 seconds
- Console warnings (not errors)
- Slightly slow page loads — wait before concluding something is broken

## How to Verify a Bug is Real

Before reporting, confirm:
1. You actually attempted the interaction — don't report based on DOM inspection alone
2. Take a screenshot if possible to show what you saw
3. Check the browser console for related errors

## Screenshot Each Confirmed Bug

Issues with a picture get fixed faster. When you confirm a bug:
1. With the buggy state still visible on screen, call browser_vision — its result
   includes a screenshot_path.
2. Copy that file to the report screenshots directory with a name describing the bug:
   `cp <screenshot_path> /opt/data/reports/screenshots/<short-bug-name>.png`
3. Add this line to the bug's section in your report:
   `Screenshot: /opt/data/reports/screenshots/<short-bug-name>.png`

One screenshot per bug is enough — take it at the moment the bug is most visible
(e.g. the saved bad value on screen, the missing error message after submit).

## Filing a Bug Report

When you find a bug, record:
- **URL** where the bug occurred — copy it exactly from the browser (navigate/snapshot
  output). Never write a URL from memory; an invented URL makes the report unusable.
- **Steps to reproduce** — from login, step by step
- **Expected behaviour** — what should have happened
- **Actual behaviour** — what actually happened
- **Severity**: Critical (blocks core flow) / High (major feature broken) / Medium (partial, workaround exists) / Low (cosmetic)
- **Console errors** if any

At the end of the test session, write all findings in a single report.
