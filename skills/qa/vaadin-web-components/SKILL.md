---
name: vaadin-web-components
title: Vaadin Web Component Testing
description: How to interact with Vaadin comboboxes and other web components via browser automation
summary: Patterns for interacting with Vaadin comboboxes, which behave differently from standard select elements.
---

# Vaadin Web Component Testing

## Critical: Vaadin Uses Shadow DOM

Vaadin components render their actual `<input>` elements inside a **Shadow DOM**. A plain
`browser_click` or `.click()` on the outer `vaadin-text-field` element hits the host element,
not the input inside. The reactive system does not fire. **You must go into the Shadow DOM.**

### Universal Pattern — Edit Any Vaadin Text Field

```javascript
(function(selector, newValue) {
  const host = document.querySelector(selector);
  if (!host) return 'NOT FOUND: ' + selector;
  const input = host.shadowRoot && host.shadowRoot.querySelector('input');
  if (!input) return 'NO INPUT IN SHADOW: ' + selector;
  input.focus();
  input.select();
  // Dispatch native input events the framework is listening to
  const nativeInputValueSetter = Object.getOwnPropertyDescriptor(
    window.HTMLInputElement.prototype, 'value').set;
  nativeInputValueSetter.call(input, newValue);
  input.dispatchEvent(new Event('input', {bubbles: true}));
  input.dispatchEvent(new Event('change', {bubbles: true}));
  input.dispatchEvent(new Event('blur',  {bubbles: true}));
  return 'SET: ' + input.value;
})('vaadin-text-field#my-field-id', 'new value here');
```

Replace `vaadin-text-field#my-field-id` with the actual selector.
Use `vaadin-integer-field`, `vaadin-number-field`, `vaadin-text-area` as needed.
Confirm by checking `input.value` in the return value.

### Find Available Fields First

Before interacting, enumerate what's actually on the page:

```javascript
[...document.querySelectorAll(
  'vaadin-text-field, vaadin-integer-field, vaadin-number-field, vaadin-text-area, vaadin-combo-box, vaadin-date-picker'
)].map(el => ({
  tag: el.tagName.toLowerCase(),
  id: el.id || '',
  label: el.getAttribute('label') || el.getAttribute('placeholder') || '',
  value: el.value || el._value || '',
  readonly: el.hasAttribute('readonly') || el.readonly || false,
  disabled: el.hasAttribute('disabled') || el.disabled || false
}))
```

### Check If a Field Is Read-Only

```javascript
const el = document.querySelector('vaadin-text-field#my-id');
({readonly: el.readonly, disabled: el.disabled, hasReadonlyAttr: el.hasAttribute('readonly')})
```

Read-only fields are not bugs — wizard-set values (salary, employment type, candidate info)
are intentionally locked.

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
