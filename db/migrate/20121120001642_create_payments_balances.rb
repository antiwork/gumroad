# frozen_string_literal: true

class CreatePaymentsBalances < ActiveRecord::Migration
  def change
    create_table :payments_balances do |t|
      t.references :payment
      t.references :balance

      t.timestamps
    end
    add_index :payments_balances, :payment_id
    add_index :payments_balances, :balance_id
  end
end
