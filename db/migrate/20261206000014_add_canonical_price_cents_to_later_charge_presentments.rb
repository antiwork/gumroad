# frozen_string_literal: true

# The canonical US-dollar price a fixing was made against — the staleness anchor.
#
# A subscription's canonical price legitimately moves mid-life: a limited-duration discount runs
# out, Subscription#update_current_plan! handles an upgrade/downgrade or quantity change, a
# SubscriptionPlanChange applies. The fixed presentment amount cannot follow those on its own, so a
# charge MUST compare the price it is about to bill against this value and fall back to canonical
# dollars when they disagree. Without it a reader cannot tell a still-valid fixing from one that
# silently under- or over-charges after a price change.
#
# This lives in its own migration rather than in CreateLaterChargePresentments (20261206000013)
# because that migration had already run on environments built earlier in this branch's life —
# preview apps and developer databases. Rails records a migration by version number, so editing an
# already-applied migration adds nothing: db:migrate sees 20261206000013 in schema_migrations,
# skips it, and the column never appears. Those databases then have a table the model cannot write
# to, failing with an unknown-attribute error on every attempt to store a fixing. A new version
# number is the only thing db:migrate will actually run.
class AddCanonicalPriceCentsToLaterChargePresentments < ActiveRecord::Migration[7.1]
  def up
    # No rows exist yet in any environment: nothing writes a fixing until the membership
    # buyer-currency lane opens, which this branch holds shut. A NOT NULL column with no default
    # is therefore safe to add outright — there is nothing to backfill. Guarded because the column
    # is present already on any database created from db.schema after this branch added it there.
    return if column_exists?(:later_charge_presentments, :canonical_price_cents)

    add_column :later_charge_presentments, :canonical_price_cents, :bigint, null: false
  end

  def down
    remove_column :later_charge_presentments, :canonical_price_cents
  end
end
