# Icon Accessibility Audit

Generated: 2025-01-10

## Summary

| Metric | Count |
|--------|-------|
| Total Icon usages | 450 |
| With `aria-label` or `aria-hidden` | 11 (2.4%) |
| Without accessibility attributes | 439 (97.6%) |
| **In interactive context needing review** | 166 |

## Risk Level: MEDIUM

Icons used as the sole content of buttons or interactive elements without `aria-label` are inaccessible to screen readers.

## Recommendation

Add `aria-label` to icons that are:
1. The only content of a button/link
2. Conveying meaningful information
3. Not purely decorative

For decorative icons, add `aria-hidden="true"`.

## Examples Needing Attention

### Audio Player (Critical - user controls)
```tsx
// Current (no accessibility)
<Icon name="circle-pause" />
<Icon name="circle-play" />
<Icon name="skip-back-15" />
<Icon name="skip-forward-30" />

// Recommended
<Icon name="circle-pause" aria-label="Pause" />
<Icon name="circle-play" aria-label="Play" />
<Icon name="skip-back-15" aria-label="Skip back 15 seconds" />
<Icon name="skip-forward-30" aria-label="Skip forward 30 seconds" />
```

### Pagination (Navigation)
```tsx
// Current
<Icon name="outline-cheveron-left" />
<Icon name="outline-cheveron-right" />

// Recommended
<Icon name="outline-cheveron-left" aria-label="Previous page" />
<Icon name="outline-cheveron-right" aria-label="Next page" />
```

### Close/Remove buttons
```tsx
// Current
<Icon name="x" />
<Icon name="x-circle" />

// Recommended
<Icon name="x" aria-label="Close" />
<Icon name="x-circle" aria-label="Remove" />
```

## Files Needing Review (Top 20)

| File | Icon Usages | Interactive Context |
|------|-------------|---------------------|
| AudioPlayer.tsx | 4 | Yes - playback controls |
| Pagination.tsx | 2 | Yes - navigation |
| Select.tsx | 4 | Yes - dropdown controls |
| Modal.tsx | 1 | Yes - close button |
| Nav.tsx | 2 | Yes - menu toggle |
| CheckoutDashboard/*.tsx | 15+ | Yes - form actions |
| Profile/EditSections.tsx | 10+ | Yes - section controls |
| ProductsPage/*.tsx | 5+ | Yes - product actions |

## Icon Component Enhancement (Optional)

Consider adding a `label` prop that maps to `aria-label`:

```tsx
type IconProps = {
  name: IconName;
  label?: string;  // Maps to aria-label
} & React.JSX.IntrinsicElements["span"];

export const Icon = ({ name, label, className, ...props }: IconProps) => (
  <span
    className={cx("icon", `icon-${name}`, className)}
    aria-label={label}
    aria-hidden={!label}
    {...props}
  />
);
```

## Note

This audit was performed as part of the `_icons.scss` migration. Fixing accessibility issues is recommended as a separate follow-up PR to maintain focused scope.
