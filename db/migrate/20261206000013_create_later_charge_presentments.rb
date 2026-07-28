# frozen_string_literal: true

class CreateLaterChargePresentments < ActiveRecord::Migration[7.1]
  def change
    create_table :later_charge_presentments do |t|
      # Polymorphic because four different things control a charge that happens after checkout,
      # and they share nothing else: a Subscription (memberships and installment plans, which are
      # subscriptions internally), a Preorder (charged on release day), and a Commission (the
      # balance payment when the seller marks the work complete). Each owns the buyer-currency
      # amount its own later charges are billed in. See LaterChargePresentment.
      #
      # Not unique on the owner: the amount legitimately gets re-fixed mid-life (a membership
      # upgrade, a quantity change, an expiring fixed-duration discount), and each fixing keeps
      # the rate it was made at. Rows are immutable and effective-dated so the drift Gumroad
      # absorbs stays measurable against the right baseline; updating one row in place would
      # overwrite it.
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
      # fixed amount was worth when they agreed to it, so the drift Gumroad absorbs afterwards can
      # be measured per owner.
      t.decimal :signup_currency_units_per_usd, precision: 30, scale: 15, null: false
      # When this amount started applying. The newest row that has taken effect is the one a
      # charge should read.
      t.datetime :effective_from, null: false

      t.timestamps

      t.index [:owner_type, :owner_id, :effective_from], name: "index_later_charge_presentments_on_owner_and_effective"
    end
  end
end
