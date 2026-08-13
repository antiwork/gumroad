Adversarial pre-merge review of gumclaw/gp1449-audience-soft-delete @ 84a5b2cb7745ccabf5fcd43568560dcf22e23cf7.

This PR replaces hard-destroy of `audience_members` with a `deleted_at` soft-delete so a later re-enable can restore the same unique `(seller_id, email)` row. It adds `db/migrate/20261208000000_add_deleted_at_to_audience_members.rb` (so this is a money/risk-tier panel) and teaches `AudienceMember.filter` to hide deleted rows. The stated production failure: a buyer unsubscribes, the row is destroyed, a support/seller `update_columns` re-enable never rebuilds it, the subscription keeps billing, and every blast misses them.

Do NOT modify files. Do not push, comment, or run the full suite. Read code only. Write findings with file:line + one-line fix. Verdict must be READY-TO-MERGE or CHANGES-REQUIRED. Use P1 (merge-blocking) / P2 / P3.

Numbered checklist — attack each item; a green suite is not evidence.

1. **Destroy→soft_delete completeness.** Grep `app/ lib/` for every `AudienceMember` `destroy!` / `destroy` / `delete` / `delete_all`. The concerns (purchase/follower/affiliate) plus `AudienceMember#refresh!` are the named sites. Any leftover hard-delete of a last-source row re-opens the exact gp#1449 hole. Classify each leftover as: still-correct (GDPR/hard-erase), missed sibling, or test-only.

2. **Who still SEES a soft-deleted row.** `filter` now adds `deleted_at: nil`. Production send paths MUST go through `filter` or they will email unsubscribed buyers (the unique index keeps the row). Grep `AudienceMember.where`, `.find_by`, `.find_or_initialize_by`, blast snapshot `pluck(:id)`, workflow recipient resolution, ES indexers, admin/CLI, and `SendPostBlastEmailsJob` / `SendWorkflowPostEmailsJob`. For each caller: is seeing the tombstone CORRECT (restore/rebuild) or a P1 leak (send/count/export)? Name file:line.

3. **`update_columns` contract in `soft_delete!`.** The comment claims it must persist emptied `details` atomically with `deleted_at`, because `update_column` would drop the in-memory empty, and the next fetch would look live. Confirm: (a) every caller mutates `details` BEFORE calling `soft_delete!`; (b) no caller then `save!`s the same object (would re-run `clear_deleted_at_when_repopulated` on leftover in-memory details); (c) `customer`/`follower`/`affiliate` boolean columns and `*_created_at` denorms are left stale on a soft-deleted row — does any reader use those flags WITHOUT going through `filter`?

4. **Restore callback polarity and order.** `clear_deleted_at_when_repopulated` is `before_validation` AFTER `compact_details`. `{}.present?` is false. Attack: (a) a save of a still-empty row after compact — must stay deleted; (b) a save that only touches email/other attrs with leftover empty details — must NOT undelete; (c) `details.present?` on a hash of blank nested purchases that compact then empties — callback already ran, so it WOULD undelete then persist empty live row. Is that reachable? (d) any path that `update_columns` / `update_all`s details without clearing `deleted_at`.

5. **Unique index `(seller_id, email)`.** Soft-delete is what makes restore work (same row). Confirm `find_or_initialize_by(email:, seller:)` does NOT scope `deleted_at: nil` (if it did, restore would try to INSERT and raise RecordNotUnique). Confirm no code path does `AudienceMember.create!` for an email that already has a tombstone.

6. **Migration / schema.** `audience_members` is not `users`/`purchases` (frozen). The migration is a bare `add_column` with no index on `deleted_at`, no `disable_ddl_transaction!`, no comment, no newline at EOF. `filter` always AND-equals `deleted_at: nil` onto `seller_id` queries. Grade whether a missing composite index is P1 (query plan on prod-sized table) or accepted. Confirm `db/schema.rb` three-dot diff is ONLY version bump + `t.datetime "deleted_at"` — no sibling-index clobber. Confirm no colliding `20261208*` version.

7. **GDPR / erasure.** `GdprBuyerErasureService` uses `AudienceMember.where(email:).update_all(anonymized_attributes)` and conflict checks by email. Soft-deleted rows still exist and still hold the email. Does erasure still hit them? Does a later restore of an anonymized tombstone resurrect a PII-wiped row as a live member? Does the unique index block a fresh member after anonymize-in-place?

8. **Default-scope temptation / counter caches.** There is no `default_scope`. That is correct for restore, dangerous for any forgotten reader (item 2). Do `customer`/`follower`/`affiliate` flags get cleared on soft-delete? If not, seller audience counts / type filters that bypass `filter` will keep counting unsubscribed buyers.

9. **Specs are load-bearing, not narrative.** The new examples assert `deleted_at` present/nil and that `filter` is empty while the tombstone exists. Demand: which example fails if (a) `soft_delete!` is swapped back to `destroy!`; (b) `filter` drops the `deleted_at: nil` clause; (c) `clear_deleted_at_when_repopulated` is deleted; (d) `soft_delete!` uses `update_column(:deleted_at, …)` and drops the details write. "None" on any of those is a coverage hole. The support-re-enable example assigns `details=` and `save!` directly — that is NOT the production `update_columns` path the comment names. If the production path never runs this callback, the example is theater.

10. **Partial class.** The root cause is "last-source removal used to destroy the row." State that sentence without naming a surface. If it covers a follower-only or affiliate-only unsubscribe that the specs never touch, the purchase-only examples are N-of-M.

Return:
- Verdict line: READY-TO-MERGE or CHANGES-REQUIRED
- Findings as `[P1|P2|P3] path:line — one-line problem — one-line fix`
- A Checked-safe list of checklist items you actually cleared, with the evidence (grep hit / read).
- Do not rubber-stamp. If you cannot verify statically, say CANNOT VERIFY STATICALLY and treat that as open, not safe.
