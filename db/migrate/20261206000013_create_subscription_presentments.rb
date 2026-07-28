# frozen_string_literal: true

class CreateSubscriptionPresentments < ActiveRecord::Migration[7.1]
  def change
    create_table :subscription_presentments do |t|
      t.references :subscription, null: false, index: { unique: true }
      t.string :presentment_currency, null: false
      # The amount the buyer agreed to and will keep being charged every period. Fixed by
      # product decision (gumroad-private#1322): a buyer who signs up at EUR 9.99/month pays
      # EUR 9.99 every month, exactly as a USD buyer pays USD 10, and Gumroad absorbs the
      # exchange-rate drift between renewals. Storing it is what makes that guarantee
      # enforceable — a rate looked up at renewal time would move the buyer's bill.
      t.bigint :presentment_price_cents, null: false
      # The rate at signup, kept for reconciliation only: it explains what the buyer's fixed
      # amount was worth when they agreed to it, so drift against a later renewal's rate can
      # be measured. It is deliberately NOT used to recompute the charge.
      t.decimal :signup_exchange_rate, precision: 20, scale: 10, null: false

      t.timestamps
    end
  end
end
