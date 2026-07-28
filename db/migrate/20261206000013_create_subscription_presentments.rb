# frozen_string_literal: true

class CreateSubscriptionPresentments < ActiveRecord::Migration[7.1]
  def change
    create_table :subscription_presentments do |t|
      # Not unique: a subscription's price legitimately changes mid-life (upgrades, downgrades,
      # quantity changes, an expiring fixed-duration discount), and under the fixed-amount rule
      # each change re-fixes the buyer-currency amount. Rows are immutable and effective-dated so
      # each period keeps the rate it was actually fixed at — updating one row in place would
      # overwrite the baseline the drift figures are measured against. See SubscriptionPresentment.
      t.references :subscription, null: false
      t.string :processor, null: false
      t.string :presentment_currency, null: false
      # The amount the buyer agreed to and keeps being charged every period. Fixed by product
      # decision (gumroad-private#1322); the model comment explains why.
      t.bigint :presentment_price_cents, null: false
      # Units of the presentment currency per 1 US dollar — the CurrencyHelper#get_rate direction
      # (EUR is about 0.89), NOT the Stripe FX quote direction. A Stripe quote's fx_rate is the
      # reciprocal, US dollars per 1 unit of the presentment currency (about 1.12 for EUR), and
      # that is what charge_presentments.fx_rate holds. Both are near 1 for most currencies, so an
      # inversion is not visible in the value; the column name carries the direction instead.
      #
      # Kept for reconciliation only, never to recompute a charge: it records what the buyer's
      # fixed amount was worth when they agreed to it, so the drift Gumroad absorbs afterwards can
      # be measured per subscription.
      t.decimal :signup_currency_units_per_usd, precision: 30, scale: 15, null: false
      # When this amount started applying. The newest row is the one a charge should read.
      t.datetime :effective_from, null: false

      t.timestamps

      t.index [:subscription_id, :effective_from], name: "index_subscription_presentments_on_subscription_and_effective"
    end
  end
end
