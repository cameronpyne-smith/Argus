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

3. **Test like a real user.** Use nav links, buttons, and forms as a user would.
   If a nav link is broken, that IS a bug — don't route around it.

4. **Exhaust alternatives before reporting blocked.** If one approach fails, try:
   - Re-snapshot and retry with fresh ref
   - JS dispatchEvent instead of browser_click
   - Navigating directly by URL as a fallback (but flag if the UI link was broken)

## Login Flow

1. Navigate to the login URL (from site-config)
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
