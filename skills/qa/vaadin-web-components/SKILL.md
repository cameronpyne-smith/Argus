---
name: vaadin-web-components
title: Vaadin Web Component Testing
description: How to interact with Vaadin comboboxes and other web components via browser automation
summary: Patterns for interacting with Vaadin comboboxes, which behave differently from standard select elements.
---

# Vaadin Web Component Testing

## Comboboxes (vaadin-combo-box)

Vaadin comboboxes are custom elements — they do not behave like `<select>`. You cannot set
their value directly. The correct pattern is: type to filter, then click the matching item.

### Pattern

1. Find the combobox input ref via snapshot
2. `browser_type <ref> <search-text>` — filters the dropdown
3. **Take a snapshot immediately** — this confirms the dropdown items have rendered. If no
   `vaadin-combo-box-item` appears in the snapshot, wait 1s and re-snapshot before clicking.
4. Click the item via `browser_console`:

```javascript
// Click the first (or only) visible item
(function(){
  document.querySelector('vaadin-combo-box-item').dispatchEvent(
    new MouseEvent('click', {bubbles: true, cancelable: true, view: window})
  );
})();
```

```javascript
// Click a specific item by text when multiple results appear
(function(){
  const items = document.querySelectorAll('vaadin-combo-box-item');
  const target = [...items].find(i => i.textContent.includes('YOUR_TEXT'));
  target.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, view: window}));
})();
```

## Committed Selection vs Typed Text

A Vaadin combobox has two states: **text typed** (not committed) and **item selected** (committed).
Only a committed selection registers as valid input to the Svelte reactive state.

Signs a selection is NOT committed:
- The combobox shows typed text but no matching item was clicked
- Dependent fields (e.g. phone number) remain disabled
- "Done" button stays disabled despite the field appearing filled

**If the vaadin-combo-box-item click throws a JS error:** the dropdown likely hadn't rendered yet.
Re-snapshot to confirm items are visible, then retry the click. Never assume typing alone is enough.

Fields are often disabled until a parent field is filled. Common patterns:
- City/Region is disabled until Country is selected
- Sub-category is disabled until a parent category is chosen

Always fill parent fields first, then re-snapshot before interacting with dependent fields.

## Checking Field State

If a "Done" or "Submit" button stays disabled, the most likely cause is a required field
not yet filled or a Vaadin combobox not having a selection committed. Re-snapshot and check
for fields still showing placeholder text.
