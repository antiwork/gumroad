# frozen_string_literal: true

class AddIndexToChargesOnStripePaymentIntentId < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    # Stripe event fallback lookups filter by payment intent and take the latest id.
    # InnoDB includes the primary key in this non-unique index, preserving that order.
    add_index :charges, :stripe_payment_intent_id
  end
end
