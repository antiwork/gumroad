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
# This lives in its own migration rather than in CreateLaterChargePresentments (20261206000017)
# because that migration had already run on environments built earlier in this branch's life —
# preview apps and developer databases. Rails records a migration by version number, so editing an
# already-applied migration adds nothing: db:migrate sees that version in schema_migrations,
# skips it, and the column never appears. Those databases then have a table the model cannot write
# to, failing with an unknown-attribute error on every attempt to store a fixing. A new version
# number is the only thing db:migrate will actually run.
class AddCanonicalPriceCentsToLaterChargePresentments < ActiveRecord::Migration[7.1]
  # Renumbered from 20261206000016 (and before that 20261206000014) after main took each version,
  # so db:migrate now runs this against databases that already have the column. Both directions
  # have to cope with that.
  SUPERSEDED_VERSION = "20261206000016"

  def up
    # No rows exist yet in any environment: nothing writes a fixing until a seller is put in the
    # :buyer_currency_subscriptions ramp, and no seller is in it. A NOT NULL column with no default
    # is therefore safe to add outright — there is nothing to backfill. Guarded because the column
    # is present already on any database created from db/schema.rb after this branch added it there.
    return if column_exists?(:later_charge_presentments, :canonical_price_cents)

    add_column :later_charge_presentments, :canonical_price_cents, :bigint, null: false
  end

  def down
    return unless column_exists?(:later_charge_presentments, :canonical_price_cents)
    # Where the superseded version is still recorded, the column belongs to that migration and a
    # rollback of this one must leave it in place. Only 16 is checked, not 14: main now uses 14 for
    # an unrelated migration, so gating on it would make this rollback a permanent no-op.
    return if superseded_version_applied?

    remove_column :later_charge_presentments, :canonical_price_cents
  end

  private
    def superseded_version_applied?
      connection.select_value(
        ActiveRecord::Base.sanitize_sql_array(
          ["SELECT 1 FROM schema_migrations WHERE version = ? LIMIT 1", SUPERSEDED_VERSION]
        )
      ).present?
    end
end
