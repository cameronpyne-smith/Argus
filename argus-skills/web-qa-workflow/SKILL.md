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

4. **Actions return a fresh snapshot for you.** `browser_click`, `browser_type`,
   `browser_select`, `browser_check`, `browser_wait`, `browser_scroll`, `browser_press`
   and `browser_back` each include the resulting page snapshot in their result — read it
   instead of spending a separate `browser_snapshot` call. Only call `browser_snapshot`
   explicitly to refresh a page that changed on its own, or with `full=true` for complete content.

5. **Exhaust alternatives before concluding something is broken.** If one approach fails, try another.
   A click that does nothing is worth retrying with a different method before reporting it.
   If a click result carries `no_visible_change: true`, the page did not change — the control may be
   disabled or the ref stale; re-snapshot and try a different element rather than repeating the click.

## Interacting with forms

Use the right verb for each control — improvising with clicks on native controls often
silently fails:
- **Dropdowns / `<select>`**: `browser_select` (by option label, value, or index). Don't click a
  native dropdown open.
- **Checkboxes / radios**: `browser_check` (`checked: false` to uncheck). Sets an explicit state.
- **File inputs**: `browser_upload`. The file must exist on disk first — create a small test file
  via the terminal (a receipt PDF/PNG, an oversized file to probe size limits, a `.exe` to probe
  type validation).
- **Async settling**: after an action that triggers loading, `browser_wait` for the expected
  element (or a short ms delay) so you observe the settled page, not a mid-transition one.

## JS errors surface automatically

Action results include `new_js_errors` when an uncaught JavaScript exception fires as a result of
that action. A JS error thrown during normal use is very often the bug itself — reproduce it and
record it. Each unique error is surfaced once per session, so if you want the full console log
(including `console.error`/warnings) call `browser_console`.

## Browser Console Rules

- **Always wrap `browser_console` JavaScript in an IIFE**: `(() => { const btn = ...; return btn?.textContent })()`.
  Consecutive evals share one JS scope — a bare `const btn = ...` will fail next time with
  "Identifier 'btn' has already been declared".
- To wait for an async UI update from inside the page: `await new Promise(r => setTimeout(r, 2000))`
  (or use the terminal: `sleep 2`), then re-snapshot.
- Use the console to *inspect* and to work around known SPA event quirks — not to bypass the UI.
  Submitting data by calling the backend API directly is never a valid test.

## Testing form fields (avoid false positives)

`browser_type` types like a real user — it fires the input events the page's
framework needs, so values DO register. `browser_click` and `browser_type`
work normally here; you do NOT need raw `dispatchEvent` JavaScript to interact.
Before reporting that a field "doesn't save", "clears itself", or "won't
persist", rule out the mundane causes first:

1. Make sure the field was actually focused/filled — re-snapshot and read its
   value back after typing.
2. If a value didn't take, the field may have been off-screen or not focused
   when you typed. Re-snapshot (refs go stale), then type again.
3. "Typed value doesn't persist" is more often a test-interaction issue than a
   site bug. Confirm the value really reached the field before reporting it.

Use **valid, well-formed test data** for the happy path, and only deliberately
malformed data when you are specifically testing validation. A field correctly
*rejecting* genuinely invalid input is NOT a bug — e.g. a UK phone in
international format is `+44 7700900123` (no leading `0` after `+44`); if you
type `+44 07700900123` and it is rejected, that is the validator working.

## Reading form-heavy pages efficiently

Accessibility snapshots often do NOT render Svelte form fields — the page looks
empty in a snapshot even when fields are present. Use `browser_vision` (a
screenshot) or one targeted `document.body.innerText` / querySelectorAll console
call to map the form ONCE, then test fields directly. Do not burn dozens of
console calls re-inspecting state every step — map once, act, re-check only what
you changed.

## Credentials

Only ever use the credentials provided in the site-config skill. Never invent, guess,
or reuse credentials from anywhere else, and never try to register new accounts unless
the task explicitly asks for it.

## Logging in

A sign-in page is just a form — drive it with the normal tools, never custom
JavaScript. This procedure is generic; the login URL and credentials come from
site-config (or your task). If a run starts unauthenticated, or testing
redirects you to a sign-in page:

1. **Navigate** to the login URL from site-config.
2. **Snapshot**, then find the **username/email** field, the **password** field,
   and the **submit** button by their role/label. `browser_type` the credentials
   into the two fields — `browser_type` fires the input events the page's
   framework needs, so you never need raw `dispatchEvent`.
3. **Verify the values stuck.** Read each field back (re-snapshot, or read its
   value). If a field is still empty after typing, your ref was stale — refs
   change after any page update. Re-snapshot and type into the NEW ref. A field
   that "won't accept input" is almost always a stale ref, not a bug.
4. **Submit** — `browser_click` the login button — then wait a couple of seconds
   and check the URL. If you are **no longer on the sign-in page**, you are in.
5. **Post-login interstitial.** If login lands on a setup / MFA / consent page
   that is not the app itself, find a **skip / later / dismiss / not now**
   control and click it. If there is genuinely no way past it, that is a real
   finding — record it and stop.
6. **If you are still on the sign-in page with no error**, re-snapshot and retry
   once (stale ref). If the credentials are explicitly **rejected**, that is the
   form working correctly for wrong input — never invent other credentials, and
   never file the login flow itself as a bug.

This covers standard form logins. SSO / passkey / captcha flows are out of scope
unless the task says otherwise.

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
