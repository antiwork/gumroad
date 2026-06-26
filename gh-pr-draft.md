# Move profile-sections orphan cleanup out of the deploy-time migration

Follow-up to #5576 / #5581.

## What

Migration `20261201000005` ran a row-by-row backfill (stripping soft-deleted product ids out of `SellerProfileProductsSection.shown_products`) inline during deploy. A Rails migration holds the migration advisory lock for its entire run, so on production data this backfill held the lock long enough to stall the deploy and risk the CI timeout.

This makes the migration a no-op (it still records the version cleanly) and moves the cleanup to an off-deploy background job:

- `Onetime::BackfillOrphanedShownProductsInProfileSections` — idempotent; reads `json_data` defensively (legacy rows can be `NULL` or hold a non-array `shown_products`); recomputes under the seller's `with_profile_sections_lock` so it can't clobber a concurrent profile edit; isolates each section so one malformed row can't abort the run.
- `BackfillOrphanedShownProductsInProfileSectionsJob` — thin Sidekiq wrapper on the `:low` queue, enqueued manually: `BackfillOrphanedShownProductsInProfileSectionsJob.perform_async`.

The migration spec is removed (behavior is now covered by the service spec).

## Why

A data backfill that iterates a large table should never gate the deploy pipeline — schema changes belong in migrations, bulk data changes belong in a job that can be paced, monitored, and re-run independently.

The cleanup is also not user-facing: the forward fix in `Link#remove_from_profile_sections!` (#5576) already prevents new orphans, and the public profile renders a section's products from search, which only returns alive products — so stale ids never render. This is internal data hygiene, which is why it's a manually-enqueued background job rather than something gating the deploy.

---

This PR was implemented with AI assistance using Claude Opus 4.8.

Prompts used:

- "will it time out potentially? wondering if the db approach makes sense or if it could be just a frontend change?"
- "[chose] cancel build, make the migration a no-op, redeploy the code fix, and re-do the cleanup as a background job"
