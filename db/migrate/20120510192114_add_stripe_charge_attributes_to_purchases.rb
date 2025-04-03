# frozen_string_literal: true

class AddStripeChargeAttributesToPurchases < ActiveRecord::Migration
  def change
    # Additional flags to keep track if something has been refunded, disputed etc.
    add_column :purchases, :amount_refunded_cents, :integer
    add_column :purchases, :stripe_disputed, :boolean
    add_column :purchases, :stripe_refunded, :boolean

    # Actually transaction information from Stripe
    add_column :purchases, :stripe_transaction_id, :string
    add_column :purchases, :stripe_fingerprint, :string
    add_column :purchases, :stripe_card_id, :string
  end
end
