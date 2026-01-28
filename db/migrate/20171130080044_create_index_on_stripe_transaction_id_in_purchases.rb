# frozen_string_literal: true

class CreateIndexOnStripeTransactionIdInPurchases < ActiveRecord::Migration[4.2]
  def change
    add_index :purchases, :stripe_transaction_id
  end
end
