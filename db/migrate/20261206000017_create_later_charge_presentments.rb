# frozen_string_literal: true

class CreateLaterChargePresentments < ActiveRecord::Migration[7.1]
  # Renumbered from 20261206000015 (and before that 20261206000013) after main took each version
  # for an unrelated table, so db:migrate now runs this migration against databases that already
  # have the table. up leaves it alone; down refuses to drop a table this migration never created,
  # which is why this is an explicit up/down pair rather than a reversible change.
  SUPERSEDED_VERSION = "20261206000015"

  def up
    create_table :later_charge_presentments, if_not_exists: true do |t|
      # Polymorphic because four different things control a charge that happens after checkout,
      # and they share nothing else: a Subscription (memberships and installment plans, which are
      # subscriptions internally), a Preorder (charged on release day), and a Commission (the
      # balance payment when the seller marks the work complete).
      #
      # Deliberately NOT unique on the owner — rows are immutable and effective-dated, one per
      # fixing. See LaterChargePresentment for why.
      t.references :owner, polymorphic: true, null: false, index: false
      t.string :processor, null: false
      t.string :presentment_currency, null: false
      # The amount the buyer agreed to and keeps being charged on every later charge. Fixed
      # rather than re-quoted, by product decision (gumroad-private#1322); the model comment
      # explains why.
      t.bigint :presentment_price_cents, null: false
      # Units of the presentment currency per 1 US dollar — the CurrencyHelper#get_rate direction
      # (EUR is about 0.89), NOT the Stripe FX quote direction. A Stripe quote's fx_rate is the
      # reciprocal, US dollars per 1 unit of the presentment currency (about 1.12 for EUR), and
      # that is what charge_presentments.fx_rate holds. Both are near 1 for most currencies, so an
      # inversion is not visible in the value; the column name carries the direction instead.
      #
      # Kept for reconciliation only, never to recompute a charge: it records what the buyer's
      # fixed amount was worth when they agreed to it, so the drift in seller proceeds afterwards can
      # be measured per owner.
      t.decimal :signup_currency_units_per_usd, precision: 30, scale: 15, null: false
      # When this amount started applying. The newest row that has taken effect is the one a
      # charge should read.
      t.datetime :effective_from, null: false

      t.timestamps

      t.index [:owner_type, :owner_id, :effective_from], name: "index_later_charge_presentments_on_owner_and_effective"
    end
  end

  def down
    return unless table_exists?(:later_charge_presentments)
    # Where the superseded version is still recorded, the table and every fixing in it belong to
    # that migration, and rolling this one back must leave them in place. Only 15 is checked, not
    # 13: main now uses 13 for an unrelated migration, so every database records it and gating on
    # it would make this rollback a permanent no-op.
    return if superseded_version_applied?

    drop_table :later_charge_presentments
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
