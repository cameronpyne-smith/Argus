---
name: vaadin-web-components
title: Vaadin Web Component Testing
description: Patterns for testing every Vaadin component type via browser automation.
summary: Browser automation patterns for Vaadin text fields, date-pickers, combo-boxes, selects, checkboxes, and grids. All use Shadow DOM or component-level APIs — never browser_click/browser_type directly on a Vaadin host element.
---

# Vaadin Web Component Testing

## The Golden Rule

**Never use `browser_click` or `browser_type` directly on this SPA.**  
Playwright's `browser_click @ref` sends a CDP-level synthetic click that does **not** trigger Svelte `on:click` event handlers. The click silently fires but nothing happens.

**Always use `browser_console` with `dispatchEvent` for every click interaction:**
```javascript
element.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, view: window}))
```

To click an element by its visible label text:
```javascript
// Find the clickable row for a field (e.g., "Start Date") and click it
(function(label) {
  var el = [...document.querySelectorAll('*')].find(function(e) {
    return e.textContent.includes(label) &&
           getComputedStyle(e).cursor === 'pointer' &&
           e.querySelectorAll('vaadin-icon, img').length > 0;
  });
  if (el) el.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, view: window}));
  return el ? 'clicked' : 'not found';
})('Start Date')
```

## Step 0 — Always Discover Fields First

> **Critical:** On most Remundo pages, Vaadin fields are rendered inside custom element
> shadow roots. A plain `document.querySelectorAll('vaadin-*')` will return an empty
> array or only find the header org-dropdown. You **must** use the recursive pierce below.

```javascript
// Recursively pierce all shadow roots to find every Vaadin field on the page
(function pierce(selector, root, out) {
  out = out || [];
  try {
    [...root.querySelectorAll(selector)].forEach(el => out.push(el));
    [...root.querySelectorAll('*')].forEach(el => {
      if (el.shadowRoot) pierce(selector, el.shadowRoot, out);
    });
  } catch(e) {}
  return out;
})(
  'vaadin-text-field,vaadin-integer-field,vaadin-number-field,vaadin-text-area,' +
  'vaadin-combo-box,vaadin-date-picker,vaadin-time-picker,vaadin-date-time-picker,' +
  'vaadin-select,vaadin-checkbox,vaadin-radio-button',
  document
).map(el => ({
  tag: el.tagName.toLowerCase(),
  id: el.id || '(no id)',
  label: el.getAttribute('label') || el.getAttribute('placeholder') || '',
  value: el.value !== undefined ? el.value : el.checked,
  readonly: el.readonly || el.hasAttribute('readonly') || false,
  disabled: el.disabled || el.hasAttribute('disabled') || false
}))
```

Use the `id` from this output as the selector in all patterns below.
If the list is empty, the section may not have rendered yet — expand it first (browser_click the accordion header) then re-run the query.
Read-only or disabled fields are **not bugs** — note them and move on.

## Warning: browser_snapshot Shows Only 1 Element on This Page

Remundo pages render content inside nested shadow DOMs. `browser_snapshot` will
typically show only a single element (e.g. `"Open Remundo AI Assistant"`).
**Do not use snapshot element count to verify the page has loaded.**

Instead, verify page load by checking `document.body.innerText` — it will contain
the full text content even when the accessibility tree is sparse.

Also wait 3+ seconds after any `browser_navigate` before querying the DOM —
the Svelte SPA renders the shell first, then hydrates shadow components.

---

## Text Fields (vaadin-text-field, vaadin-integer-field, vaadin-number-field, vaadin-text-area)

Uses the Shadow DOM `nativeInputValueSetter` pattern. Because fields are inside nested
shadow roots, use `id` from the Step 0 discovery to target precisely:

```javascript
(function(fieldId, newValue) {
  // Pierce all shadow roots to find the field by id
  function pierce(sel, root, out) {
    out = out || [];
    try {
      [...root.querySelectorAll(sel)].forEach(el => out.push(el));
      [...root.querySelectorAll('*')].forEach(el => { if (el.shadowRoot) pierce(sel, el.shadowRoot, out); });
    } catch(e) {}
    return out;
  }
  const host = pierce('#' + fieldId, document)[0];
  if (!host) return 'NOT FOUND: #' + fieldId;
  if (host.readonly || host.disabled) return 'READONLY/DISABLED';
  const input = host.shadowRoot && host.shadowRoot.querySelector('input, textarea');
  if (!input) return 'NO INPUT IN SHADOW';
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
  setter.call(input, newValue);
  input.dispatchEvent(new Event('input',  {bubbles: true}));
  input.dispatchEvent(new Event('change', {bubbles: true}));
  input.dispatchEvent(new Event('blur',   {bubbles: true}));
  return 'SET: ' + input.value;
})('your-field-id', 'new value');
```

Replace `'your-field-id'` with the `id` from the Step 0 discovery output.
Confirm the return says `SET: new value`. If it returns `READONLY/DISABLED`, note the field and skip.

---

## Date Pickers (vaadin-date-picker)

Date-pickers use a component-level `value` property (ISO format `YYYY-MM-DD`).
**Do not try to type into the shadow input directly — use this pattern:**

```javascript
(function(selector, isoDate) {
  // isoDate must be YYYY-MM-DD, e.g. '2026-06-15'
  // Use the recursive pierce from Step 0 to find the selector first
  function pierce(sel, root, out) {
    out = out || [];
    try {
      [...root.querySelectorAll(sel)].forEach(el => out.push(el));
      [...root.querySelectorAll('*')].forEach(el => { if (el.shadowRoot) pierce(sel, el.shadowRoot, out); });
    } catch(e) {}
    return out;
  }
  const results = pierce(selector, document);
  const el = results[0];
  if (!el) return 'NOT FOUND: ' + selector;
  if (el.readonly || el.disabled) return 'READONLY/DISABLED';
  el.value = isoDate;
  el.dispatchEvent(new CustomEvent('change', {bubbles: true}));
  el.dispatchEvent(new CustomEvent('value-changed', {bubbles: true, detail: {value: isoDate}}));
  return 'SET: ' + el.value;
})('vaadin-date-picker', '2026-06-15');
```

If the element has an `id`, use `'vaadin-date-picker#field-id'` as the selector.

**After clicking a field to open it, check for the overlay:**

```javascript
// Did a date-picker or dialog overlay appear after clicking?
[...document.querySelectorAll(
  'vaadin-date-picker-overlay, vaadin-date-picker-overlay-content, ' +
  'vaadin-dialog-overlay, vaadin-overlay'
)].map(el => ({tag: el.tagName.toLowerCase(), opened: el.opened || !el.hidden}))
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
