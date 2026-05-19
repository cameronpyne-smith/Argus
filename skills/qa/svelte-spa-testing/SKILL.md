---
name: svelte-spa-testing
title: Svelte SPA Browser Testing
description: How to interact with Svelte-rendered components that filter synthetic browser events
summary: Patterns for clicking Svelte components that ignore standard browser_click automation.
---

# Svelte SPA Browser Testing

## The Problem

Svelte components use `on:click` event handlers that only fire for genuine user interactions.
Standard `browser_click <ref>` sends a synthetic event that Svelte filters out — the click
appears to succeed but nothing happens (no error, no page change).

## How to Detect It

If you click a button and:
- No error is thrown
- The element exists in the snapshot
- But nothing happens (URL unchanged, form not submitted, state not updated)

...you are likely hitting Svelte's synthetic event filter. Switch to `dispatchEvent`.

## The Fix

Use `browser_console` to dispatch a MouseEvent with `bubbles: true` and `view: window`:

```javascript
// Click by CSS selector
(function(){
  const el = document.querySelector('YOUR_SELECTOR');
  el.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, view: window}));
})();
```

```javascript
// Click by visible text content
(function(){
  const btn = [...document.querySelectorAll('button')].find(b => b.textContent.trim() === 'Log in');
  btn.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, view: window}));
})();
```

## When to Use dispatchEvent vs browser_click

**Use browser_click (standard) for:**
- `<a>` anchor/nav links
- Native `<input type="radio">` and `<input type="checkbox">`
- HTML buttons that are NOT Svelte component event handlers

**Use dispatchEvent for:**
- Buttons inside Svelte components where browser_click silently does nothing
- Any button where clicking produces no observable effect despite the element being present

## Diagnosing a Failed Click

1. Take snapshot — confirm the element is present and not disabled
2. Try `browser_click <ref>`
3. Re-snapshot — if nothing changed, try `dispatchEvent`
4. If `dispatchEvent` also fails, check: is the element inside a shadow DOM? Is it actually visible (not hidden by CSS)?
