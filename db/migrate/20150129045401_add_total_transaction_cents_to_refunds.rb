# frozen_string_literal: true

class AddTotalTransactionCentsToRefunds < ActiveRecord::Migration
  def change
    add_column :refunds, :total_transaction_cents, :integer
  end
end
