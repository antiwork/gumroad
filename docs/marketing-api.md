# Marketing API v2

All endpoints use the same `edit_emails` OAuth authorization as `/v2/emails` (including the legacy `account` fallback). The seller must have `auto_marketing` enabled; otherwise every endpoint returns HTTP 404. Products and actions are scoped to the token's seller. No scheduler or marketing state lives in the client.

## Endpoints

- `GET /v2/products/:product_id/marketing/recommendations`: returns `{success: true, channels: [...]}` using `Marketing::Recommendations`. Accepts a product external ID or permalink. Only published products; prepares one open action and tagged link per live channel, without posting.
- `POST /v2/products/:product_id/marketing_actions`, with `channel=x`: explicitly prepares/reuses the same recommendation and returns `{success: true, marketing_action: {...}, handle: "..."}`. Reuses an open action, but a new recommendation after a terminal action is a new intent, not a retry. Retry an existing action by its ID, never by requesting another recommendation.
- `GET /v2/marketing_actions/:id`: returns the action and account handle without creating anything.
- `POST /v2/marketing_actions/:id/approve`: approves the existing row; optional `copy` is validated by the shared model. Requires `idempotency_key` and `confirmation_token` from the reviewed action. This does not post.
- `POST /v2/marketing_actions/:id/execute`: executes the existing approved action through the channel executor. Requires the same keys. Execution is immediate; there is no future-time scheduling API in this version.
- `POST /v2/marketing_actions/:id/cancel`: cancels an unclaimed action; requires its `idempotency_key`. Repeated cancellation returns the same row. Claimed or posted actions cannot be cancelled.

The action includes `id`, `idempotency_key`, `confirmation_token`, `channel`, `status`, `copy`, `post_text`, `link_url`, `external_url`, `error_code`, `approved_at`, and `posted_at`. Keys are opaque; store and return them unchanged. The stable idempotency key derives from the existing persisted key without exposing internal IDs. The confirmation token binds the reviewed text, link and account; copy/account changes after preview are refused before approval or the outbound claim. An edited approval returns a new confirmation token.

Execute also returns `intent_url` and `connect_path` for the existing reconnect/manual-share fallback. HTTP 200 indicates the action was processed, not necessarily posted: inspect `marketing_action.status` and `error_code`. A permission refusal stays approved for reconnect; an ambiguous outbound result is never resent. Repeated approve/execute requests for a posted action return the same row without a second post.

Validation failures return HTTP 422 with `{success: false, message: "..."}`. Missing authentication returns 401, insufficient scope 403, and missing/foreign resources 404.

## CLI and Gumhead post-publish flow

1. `GET /v2/products/:id/marketing/recommendations` after publishing. Select a live channel and display its `handle`, `action.post_text`, and `action.link_url`. Do not approve automatically.
2. After the seller explicitly confirms, `POST /v2/marketing_actions/:action_id/approve` with `idempotency_key` and `confirmation_token` from that preview (and optional seller-edited `copy`).
3. `POST /v2/marketing_actions/:action_id/execute` with the keys from the approve response. Resolve retries with the same action ID; `GET /v2/marketing_actions/:action_id` shows the outcome.
4. Offer cancellation before execution via `POST /v2/marketing_actions/:action_id/cancel`, with `idempotency_key`.

The companion CLI exposes `marketing recommend`, `approve`, `schedule`, `cancel`, and `status`. `schedule` invokes the immediate execute endpoint; it does not accept a future date. Merge and deploy this Rails API before merging/releasing the CLI. Gumhead consumes these calls; this change does not modify Gumhead.
