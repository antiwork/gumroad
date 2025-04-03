# frozen_string_literal: true

class AddBalanceIdsToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :purchase_success_balance_id, :integer
    add_column :purchases, :purchase_chargeback_balance_id, :integer
    add_column :purchases, :purchase_refund_balance_id, :integer
  end
end
