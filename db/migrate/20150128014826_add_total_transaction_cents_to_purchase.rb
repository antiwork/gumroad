# frozen_string_literal: true

class AddTotalTransactionCentsToPurchase < ActiveRecord::Migration
  def change
    add_column :purchases, :total_transaction_cents, :integer
  end
end
