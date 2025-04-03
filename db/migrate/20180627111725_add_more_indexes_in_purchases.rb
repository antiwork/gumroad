# frozen_string_literal: true

class AddMoreIndexesInPurchases < ActiveRecord::Migration
  def change
    add_index :purchases, :purchase_refund_balance_id
    add_index :purchases, :purchase_chargeback_balance_id
    add_index :purchases, :purchase_success_balance_id
  end
end
