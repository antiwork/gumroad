# Feature proposal: Cmd/Ctrl+S to Save in Product Editor

Problem
- While editing a product, users frequently reach for Cmd/Ctrl+S to save. Currently, this triggers the browser’s default “Save Page” and does nothing useful in the app. It’s a small but recurring UX papercut that adds friction.

Proposal
- Add a keyboard shortcut handler in the product editor layout so Cmd+S (macOS) or Ctrl+S (Windows/Linux) triggers the existing Save action, if the editor isn’t busy (saving or uploading).
- Expose the shortcut via aria-keyshortcuts on the Save button for accessibility and discoverability.

Scope
- JavaScript-only change in app/javascript/components/ProductEdit/Layout.tsx.
- No backend or API changes.

Acceptance Criteria
- Pressing Cmd+S (macOS) or Ctrl+S (Windows/Linux) on any tab within the product editor invokes the same handler as clicking “Save changes”.
- Default browser “Save page” is prevented while on the product editor.
- Shortcut is disabled while saving or while files/images are uploading, matching the button’s disabled state.
- Save button includes aria-keyshortcuts="Control+S Meta+S" for assistive tech.

Why it matters
- Reduces micro-friction and jank when iterating on product details.
- Aligns with common editor conventions, making the UI feel more responsive and polished.

Test Plan
- Manual: Open product editor, make a change, press Cmd/Ctrl+S, observe toast and persisted changes.
- Manual: While an upload is in progress, press Cmd/Ctrl+S and verify no save triggers and a warning tooltip remains (button disabled).
- Automated (optional): Add a unit test for the handler that ensures preventDefault is called and save() is invoked when not busy.

Docs
- Add a short note in README Development section about the new shortcut.

