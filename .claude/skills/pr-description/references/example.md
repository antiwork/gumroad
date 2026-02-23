# Example: Well-Received PR Description

This PR was well-received by the Gumroad team. Use it as a style reference.

```markdown
Fixes #2562

## Problem

Inertia.js caches the entire `page.props` object in browser history state. When users navigate backward/forward, the browser restores the cached props including the flash message, causing it to re-render even though it was already displayed.

## Approach

Clear the flash prop from Inertia's cache immediately after displaying the message using `router.replaceProp("flash", null)`. This is a client-side operation that modifies the current page state without making a server request.

Created a `useFlashMessage` hook that displays the flash and clears it from cache, then updated the layouts to use it.

### Why This Approach

Other open PRs for this issue:

- **#2655** uses server-side ID generation + sessionStorage tracking (adds backend changes and storage management)
- **#2614** removes flash from Inertia props entirely (invasive restructure)
- **#2613** uses `router.replace({ props: ... })` (similar concept, older API)

This PR uses `router.replaceProp()` — the direct Inertia v2 API designed for single-prop updates. No server changes, no storage management, minimal code.

## Before/After

Before:
https://github.com/user-attachments/assets/46a53f8e-cb14-4930-8301-34943af3a5f2

After:
https://github.com/user-attachments/assets/23efb2b5-c533-4ec4-9a29-59ee7a07c1cd

## Test Results

<img width="602" height="141" alt="Screenshot 2026-01-06 at 23 10 31" src="https://github.com/user-attachments/assets/d7b2ba00-5007-4100-bb0a-85b6fb04d87f" />

---

This PR was implemented with AI assistance using Claude Code for code generation. All code was self-reviewed.
```
