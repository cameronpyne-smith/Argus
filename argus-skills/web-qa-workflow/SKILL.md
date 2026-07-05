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
   `browser_fill_form`, `browser_select`, `browser_check`, `browser_wait`, `browser_scroll`,
   `browser_press` and `browser_back` each include the resulting page snapshot in their
   result — read it instead of spending a separate `browser_snapshot` call. Only call
   `browser_snapshot` explicitly to refresh a page that changed on its own, or with
   `full=true` for complete content.

5. **Exhaust alternatives before concluding something is broken.** If one approach fails, try another.
   A click that does nothing is worth retrying with a different method before reporting it.
   If a click result carries `no_visible_change: true`, the page did not change — the control may be
   disabled or the ref stale; re-snapshot and try a different element rather than repeating the click.

## Interacting with forms

**Filling more than one field? Use `browser_fill_form` — one call, not one per field.**
It sets every field (and optionally clicks submit) in a single tool call, so a six-field
form costs one turn instead of six. Pass `fields: [{ref, value, type}]` where `type` is
`text` (default), `select`, or `checkbox` (`value` `"true"`/`"false"`), plus `submit_ref`
to submit. It reports per-field results, so if a ref was stale you re-fill only that field.
Reach for the single-field verbs below only when you are touching exactly one control or
need to react to the page between fields.

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
4. A button that "does nothing" or "stays disabled" is usually NOT a site bug:
   the ref went stale after a re-render, or a required control is not yet
   satisfied. Vaadin comboboxes in particular need a COMMITTED selection — pick
   an option and see the value land in the field — before dependent fields or
   the submit button enable. Re-snapshot for a fresh ref, confirm every required
   field shows a committed value, then click the fresh ref. NEVER force a click
   or set a value with JavaScript (`.click()`, `el.value`, `dispatchEvent`) — it
   bypasses the framework and manufactures false results. If the real control
   still will not respond after a fresh snapshot and satisfied requirements, THAT
   is your evidence — record it — but a JS-forced "fix" never is.
5. Do NOT diagnose the page with `document.querySelectorAll(...)` and conclude it
   is "empty" or "crashed". These apps render inside shadow DOM and web
   components, so a plain querySelector sees 0 inputs even when the fields are
   present and fully usable. Trust the accessibility snapshot and actual
   interaction (browser_vision if unsure), never a raw DOM count.

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
   and the **submit** button by their role/label. Fill both fields and submit in
   ONE `browser_fill_form` call: `fields: [{ref: <user>, value: <email>}, {ref:
   <pass>, value: <password>}]`, `submit_ref: <login button>`. This fires the
   input events the page's framework needs (no raw `dispatchEvent`) and its
   result reports whether each field took.
3. **Verify the values stuck.** `browser_fill_form` reports any field that didn't
   fill (a stale ref — refs change after any page update). If it lists a failed
   field, re-snapshot and re-fill the NEW ref. A field that "won't accept input"
   is almost always a stale ref, not a bug.
4. **After submit** — the fill result includes the post-submit snapshot; wait a
   couple of seconds if needed and check the URL. If you are **no longer on the
   sign-in page**, you are in. (If you filled the fields separately instead, click
   the login button with `browser_click`.)
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

## Deeper bug classes — where the bugs others miss actually live

Malformed single-field input (above) is the shallow 30%. The bugs a senior QA
finds are about STATE and SEQUENCE, not one field in isolation. On every area,
pick the ones that fit and actually perform the sequence — reproduce the outcome,
never infer it:

- **Persistence across reloads.** Save data, then reload the page, navigate away
  and back, or re-login. Data that silently disappears, reverts, or shows a stale
  value is a bug.
- **Full lifecycle.** Create → edit → delete a record, then try to use or undo it.
  Does a deleted item still show in lists, dropdowns, counts, or totals? Can you
  still open/edit something you just deleted?
- **Cross-view consistency.** The same data is usually shown in more than one
  place — a count or total on a dashboard vs the actual rows in the list, a value
  in a list row vs that record's detail page, an option in a dropdown vs the table
  it comes from, a badge vs the thing it counts. After ANY create, edit or delete,
  read at least two views of the affected data and check they still AGREE. A count
  that doesn't update, a deleted item lingering in a dropdown, a total that
  disagrees with its line items, a detail page showing a different value than the
  list — these are stale / derived-state bugs, and they are invisible if you only
  look at the one view you just changed. This is a general oracle: you don't need a
  visible error to call it a bug — two views of the same fact that disagree IS the
  bug.
- **Interrupted / resumed flows.** Start a multi-step wizard, leave halfway
  (navigate away, browser Back, reload), then return. Is partial state saved
  sanely, or is it half-committed, duplicated, or silently lost?
- **Back / forward / refresh / double-submit.** Use the browser Back button after
  a submit, refresh a confirmation page, click submit twice, or go Back and
  re-submit. Watch for duplicate records or a resurrected stale form.
- **Conditional / dependent fields.** When one field changes what another allows
  (country → address format, type → available options), change the driver AFTER
  filling the dependent field and check the dependent updates or clears correctly.
- **Error recovery.** Force a save to fail (invalid value, or a required field
  blank), then fix it and continue. Is the form left consistent, or stuck /
  duplicated / silently broken afterwards?
- **Empty / boundary collections.** Filter or search to zero results, paginate
  past the last page, sort an empty list. A blank screen with no empty-state
  message is a bug.

## Access-control probes (the highest-severity, most-missed bugs)

The worst bugs are usually authorization failures, not bad input — and automated
QA almost never looks for them. On any page that carries an **id in the URL** (an
org UUID, a record id, `/organisations/<uuid>/…`, `/invoices/<id>`, `?id=123`),
probe whether the app enforces who may see and do what:

- **Mutate the id (IDOR).** Change an id in the current URL to a *different* one —
  another id you saw elsewhere on the site, an adjacent value, or a well-formed
  but foreign UUID — and navigate there while logged in as yourself. The correct
  result is a clean denial: "not authorised", a redirect, or a 404. LEAKING
  another party's data, or letting you act on it, is a **Critical** bug. A 500 /
  stack trace on a foreign id is also a bug (information disclosure / missing
  authz check).
- **Cross-persona URLs.** site-config may list URLs or ids belonging to a
  *different* persona than the one you logged in as. Navigate straight to one. You
  should be denied; seeing that persona's data is Critical.
- **Privileged actions from a lower-privilege account.** If your persona is not an
  admin/owner, try to reach admin/owner-only pages or actions by their URL
  directly. Reaching them is a bug; a clean denial is correct.
- **Deep-link past a flow.** Jump straight to an inner/confirmation page without
  the steps that normally precede it — is login/permission still enforced, or does
  it render with stale or someone else's state?

Stay within your own login — only ever authenticate with YOUR persona's real
credentials from site-config. These probes are about reaching URLs and ids you
are not meant to reach *while logged in as yourself*, never about logging in as
someone else or guessing passwords. In the bug, record the exact id/URL you
changed, from what to what, and precisely what leaked or errored.

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
