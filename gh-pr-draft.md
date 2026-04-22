Fixes #4477

## What

Adds public API documentation for creating and updating products (`POST /v2/products` and `PUT /v2/products/:id`).

The new sections list every supported field, the response shape, and the follow-up endpoints for files, covers, and thumbnails. They also flag a few non-obvious behaviors that tripped the issue reporter — notably that updating the `files` list replaces it entirely, and that keeping an existing file requires sending it back with the URL from the upload flow, not the one returned by `GET`.

## Why

The create and update endpoints shipped without docs, so users had to guess the request shape and kept hitting silent failures. This closes that gap.

Scope is docs-only. The related upload-flow docs (#4557) and stricter input validation (#4559) already shipped.

---

This PR was implemented with AI assistance using Claude Opus 4.7 (1M context).

Prompts used:

- "implement PR 3 from the plan at .context/attachments/api-docs-and-ux-fixes-plan.md"
- "validate with /codex:adversarial-review and address findings if any, and repeat this loop in sequence until no worthy findings remain"
- "pull main latest, rebase main, then squash commits and push"
- "pr should be more concise and high level, avoid jargon"
