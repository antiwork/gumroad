# frozen_string_literal: true

class CreateIndexOnStripeTransactionIdInPurchases < ActiveRecord::Migration
  def change
    add_index :purchases, :stripe_transaction_id
  end
end
