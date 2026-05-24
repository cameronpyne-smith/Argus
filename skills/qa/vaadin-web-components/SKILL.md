---
name: vaadin-web-components
title: Vaadin Web Component Testing
description: Patterns for testing every Vaadin component type via browser automation.
summary: Browser automation patterns for Vaadin text fields, date-pickers, combo-boxes, selects, checkboxes, and grids. All use Shadow DOM or component-level APIs — never browser_click/browser_type directly on a Vaadin host element.
---

# Vaadin Web Component Testing

## The Golden Rule

**Never use `browser_click` or `browser_type` directly on a Vaadin host element.**  
Vaadin components render their real inputs inside a Shadow DOM. A plain click hits the host,
not the input — the reactive framework never fires and nothing changes.

## Step 0 — Always Discover Fields First

Before touching anything, run this to see every Vaadin field on the page:

```javascript
[...document.querySelectorAll(
  'vaadin-text-field, vaadin-integer-field, vaadin-number-field, vaadin-text-area,' +
  'vaadin-combo-box, vaadin-date-picker, vaadin-time-picker, vaadin-date-time-picker,' +
  'vaadin-select, vaadin-checkbox, vaadin-radio-button'
)].map(el => ({
  tag: el.tagName.toLowerCase(),
  id: el.id || '(no id)',
  label: el.getAttribute('label') || el.getAttribute('placeholder') || '',
  value: el.value !== undefined ? el.value : el.checked,
  readonly: el.readonly || el.hasAttribute('readonly') || false,
  disabled: el.disabled || el.hasAttribute('disabled') || false
}))
```

Use the `id` from this output as the selector in all patterns below.
Read-only or disabled fields are **not bugs** — note them and move on.

---

## Text Fields (vaadin-text-field, vaadin-integer-field, vaadin-number-field, vaadin-text-area)

Uses the Shadow DOM `nativeInputValueSetter` pattern:

```javascript
(function(selector, newValue) {
  const host = document.querySelector(selector);
  if (!host) return 'NOT FOUND: ' + selector;
  if (host.readonly || host.disabled) return 'READONLY/DISABLED';
  const input = host.shadowRoot && host.shadowRoot.querySelector('input, textarea');
  if (!input) return 'NO INPUT IN SHADOW: ' + selector;
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
  setter.call(input, newValue);
  input.dispatchEvent(new Event('input',  {bubbles: true}));
  input.dispatchEvent(new Event('change', {bubbles: true}));
  input.dispatchEvent(new Event('blur',   {bubbles: true}));
  return 'SET: ' + input.value;
})('vaadin-text-field#field-id', 'new value');
```

Confirm the return says `SET: new value`. If it returns `READONLY/DISABLED`, note the field and skip.

---

## Date Pickers (vaadin-date-picker)

Date-pickers use a component-level `value` property (ISO format `YYYY-MM-DD`).
**Do not try to type into the shadow input directly — use this pattern:**

```javascript
(function(selector, isoDate) {
  // isoDate must be YYYY-MM-DD, e.g. '2026-06-15'
  const el = document.querySelector(selector);
  if (!el) return 'NOT FOUND: ' + selector;
  if (el.readonly || el.disabled) return 'READONLY/DISABLED';
  el.value = isoDate;
  el.dispatchEvent(new CustomEvent('change', {bubbles: true}));
  el.dispatchEvent(new CustomEvent('value-changed', {bubbles: true, detail: {value: isoDate}}));
  return 'SET: ' + el.value;
})('vaadin-date-picker#field-id', '2026-06-15');
```

**Edge cases to test:**
- Past date (e.g. `'2000-01-01'`)
- Far-future date (e.g. `'2099-12-31'`)
- Invalid string (e.g. `'not-a-date'`) — expect the field to reject it or show an error
- Empty string `''` — should clear the field; check if a required-field error appears

---

## Time Pickers (vaadin-time-picker)

Same approach as date-picker but value is `HH:MM` or `HH:MM:SS`:

```javascript
(function(selector, timeValue) {
  const el = document.querySelector(selector);
  if (!el) return 'NOT FOUND: ' + selector;
  if (el.readonly || el.disabled) return 'READONLY/DISABLED';
  el.value = timeValue;
  el.dispatchEvent(new CustomEvent('change', {bubbles: true}));
  el.dispatchEvent(new CustomEvent('value-changed', {bubbles: true, detail: {value: timeValue}}));
  return 'SET: ' + el.value;
})('vaadin-time-picker#field-id', '09:30');
```

---

## Combo Boxes (vaadin-combo-box)

Combo-boxes require two steps: type to filter, then click the matching item.
**Do not set `.value` directly — the selection will not commit.**

```javascript
// Step 1: Open the dropdown and filter
// Use browser_type on the shadow input, OR open the dropdown via component API:
(function(selector) {
  const el = document.querySelector(selector);
  if (!el) return 'NOT FOUND';
  el.opened = true;
  el.filter = '';
  return 'OPENED';
})('vaadin-combo-box#field-id');
```

Then take a snapshot to confirm items appeared, then:

```javascript
// Step 2: Click the matching item by label text
(function(labelText) {
  const items = document.querySelectorAll('vaadin-combo-box-item');
  const target = [...items].find(i => i.textContent.trim().includes(labelText));
  if (!target) return 'ITEM NOT FOUND: ' + labelText;
  target.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, view: window}));
  return 'CLICKED: ' + target.textContent.trim();
})('Option Label Text');
```

**Signs a selection is NOT committed:**
- Dependent fields stay disabled
- Save button stays disabled despite field appearing filled

Always fill parent combo-boxes before child ones (e.g. Country → City).

---

## Select Dropdowns (vaadin-select)

Vaadin selects have fixed options (no typing). Set the value directly:

```javascript
(function(selector, value) {
  const el = document.querySelector(selector);
  if (!el) return 'NOT FOUND: ' + selector;
  if (el.readonly || el.disabled) return 'READONLY/DISABLED';
  el.value = value;
  el.dispatchEvent(new CustomEvent('change', {bubbles: true}));
  el.dispatchEvent(new CustomEvent('value-changed', {bubbles: true, detail: {value}}));
  return 'SET: ' + el.value;
})('vaadin-select#field-id', 'option-value');
```

To discover valid option values:

```javascript
// Open the overlay to inspect available options
const el = document.querySelector('vaadin-select#field-id');
el.opened = true;
// Then snapshot — items render in the overlay
```

---

## Checkboxes (vaadin-checkbox)

```javascript
(function(selector, checked) {
  const el = document.querySelector(selector);
  if (!el) return 'NOT FOUND: ' + selector;
  if (el.disabled) return 'DISABLED';
  if (el.checked === checked) return 'ALREADY: ' + checked;
  el.checked = checked;
  el.dispatchEvent(new Event('change', {bubbles: true}));
  el.dispatchEvent(new CustomEvent('checked-changed', {bubbles: true, detail: {value: checked}}));
  return 'SET: ' + el.checked;
})('vaadin-checkbox#field-id', true);
```

---

## Radio Buttons (vaadin-radio-button / vaadin-radio-group)

```javascript
// Select a radio option by value within a group
(function(groupSelector, value) {
  const group = document.querySelector(groupSelector);
  if (!group) return 'NOT FOUND';
  group.value = value;
  group.dispatchEvent(new CustomEvent('value-changed', {bubbles: true, detail: {value}}));
  return 'SET: ' + group.value;
})('vaadin-radio-group#field-id', 'option-value');
```

---

## Checking If a Field Is Read-Only

```javascript
(function(selector) {
  const el = document.querySelector(selector);
  if (!el) return 'NOT FOUND';
  return {
    readonly: el.readonly,
    disabled: el.disabled,
    readonlyAttr: el.hasAttribute('readonly'),
    disabledAttr: el.hasAttribute('disabled')
  };
})('vaadin-text-field#field-id');
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `browser_type` reports success but value unchanged | Hit shadow host, not real input | Use Shadow DOM setter pattern above |
| `browser_click` does nothing | Same — Shadow DOM | Use `dispatchEvent` on the element |
| `value-changed` event doesn't stick | Component not connected to reactive state | Also dispatch `change` — Svelte listens to both |
| Combo-box item not found | Dropdown not opened yet | Set `el.opened = true` first, snapshot, then click item |
| Date-picker value not accepted | Wrong format | Must be `YYYY-MM-DD` ISO string |
| Field still disabled after filling parent | Parent not committed | Click a combo-box item (don't just type), then wait 500ms |
