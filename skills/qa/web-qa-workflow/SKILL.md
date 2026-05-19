---
name: web-qa-workflow
title: Web QA Testing Workflow
description: Systematic approach for QA testing web applications with browser automation
summary: General workflow and principles for browser-based QA testing — snapshot discipline, retry patterns, bug reporting.
---

# Web QA Testing Workflow

## Core Principles

1. **Snapshot before every interaction.** Refs are ephemeral — they change after every
   navigation or DOM update. Never reuse a ref from a previous snapshot.

2. **Re-snapshot after every click.** Confirm the outcome before drawing conclusions.
   A click that produces no change is itself a finding.

3. **Re-snapshot after receiving a user reply.** Assume all refs are stale when resuming.
   If the page is blank or you're at login, re-login and navigate back before continuing.

4. **Test like a real user.** Use nav links, buttons, and forms as a user would.
   If a nav link is broken, that IS a bug — don't route around it.

5. **Never use visual coordinate clicking (browser_vision).** Always use refs or JS.

6. **Exhaust alternatives before reporting blocked.** If one approach fails, try:
   - Re-snapshot and retry with fresh ref
   - JS dispatchEvent instead of browser_click (see `svelte-spa-testing` skill)
   - Navigating directly by URL as a last resort (but flag if the UI link was broken)

## Clicking Elements

- **`browser_click <ref>`** — use for nav links, radio buttons, checkboxes, standard buttons
- **If `browser_click` silently does nothing** — the site may filter synthetic events (e.g. Svelte). Consult `svelte-spa-testing` skill.
- **If `browser_click` fails with "unknown ref"** — ref is stale, re-snapshot and retry
- **Fallback for links by text** (only after re-snapshot + retry fails):
  ```javascript
  (function(){const link=[...document.querySelectorAll('a')].find(a=>a.textContent.trim().includes('TARGET_TEXT'));link?.click();})();
  ```
  If this also fails, report it as a navigation bug.

## Reading a Page

**Always use `snapshot -i`** (interactive elements only) not plain `snapshot`. Plain snapshot returns structural noise including CSS classes that look meaningful but aren't.

```bash
agent-browser snapshot -i          # interactive elements only — use this
agent-browser snapshot -i -u       # also shows href on links
agent-browser snapshot -i -c       # compact, no empty nodes
```

**Use `screenshot` + `browser_vision` to confirm visual state** before reporting any bug. The accessibility tree can be misleading — CSS class names like `disabled` are styling only, not proof an element is broken. Always confirm visually or by attempting the interaction.

```bash
agent-browser screenshot /tmp/page.png   # take a screenshot
# then use browser_vision to analyse what you actually see
```

**Wait for the page to settle** before snapshotting after navigation or async actions:
```bash
agent-browser wait --load networkidle
agent-browser snapshot -i
```

## Verifying Bugs

**Do not report something as a bug based on the accessibility tree alone.** The snapshot reflects DOM structure, not user experience. Common false positives:

- CSS class `disabled` on an element — this is styling only, not a real disabled state. Test by actually clicking or interacting with it.
- Missing elements in the snapshot — custom components (Svelte, Vaadin) often render incompletely in the accessibility tree. Use `eval` or `screenshot` to verify.
- Empty snapshot — the page may still be loading. Use `wait --load networkidle` and re-snapshot.

**To confirm a bug is real:**
1. Take a `screenshot` and use `browser_vision` to see it as a user would
2. Actually attempt the interaction — does it fail in the way you expect?
3. Check the browser console for real errors (not just `[warning]` logs)

## Login Flow
2. Snapshot → find email and password input refs
3. Type credentials into both fields
4. Snapshot → confirm submit button is enabled (not disabled)
5. Submit (use dispatchEvent if the site uses a JS framework like Svelte/React)
6. Wait and verify you reached an authenticated page (dashboard, home, etc.)

## Testing Navigation

After login, systematically test each section of the app:
1. Click a nav link using `browser_click <ref>`
2. Re-snapshot and verify URL changed to the expected route
3. If URL did not change → **navigation bug** — log it
4. Explore the section: test forms, buttons, data display

## Handling Async Pages

Some UI updates are asynchronous (loading spinners, generated content):
- Wait briefly (3-5s) after triggering an async action before snapshotting
- If a spinner is still showing, wait more before concluding something is broken
- Distinguish between "slow" and "broken" — retry once before filing a bug

## Filing Issues

When you find a bug:
1. Capture the exact URL
2. Write clear reproduction steps (from login, step by step)
3. State expected vs actual behaviour
4. Note any console errors (use `browser_console` to check)
5. Assign severity:
   - **Critical**: Blocks core user flow (can't login, can't complete a key action)
   - **High**: Major feature broken or data loss risk
   - **Medium**: Feature partially works, workaround exists
   - **Low**: Minor UX issue, cosmetic problem
6. Run: `gh issue create --title "..." --body "..."`
