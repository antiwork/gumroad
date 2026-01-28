# frozen_string_literal: true

class AddTotalTransactionCentsToPurchase < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :total_transaction_cents, :integer
  end
end
