# frozen_string_literal: true

class AddTotalTransactionCentsToRefunds < ActiveRecord::Migration[4.2]
  def change
    add_column :refunds, :total_transaction_cents, :integer
  end
end
