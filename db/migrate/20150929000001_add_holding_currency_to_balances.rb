# frozen_string_literal: true

class AddHoldingCurrencyToBalances < ActiveRecord::Migration
  def up
    add_column :balances, :currency, :string, default: "usd"
    add_column :balances, :holding_currency, :string, default: "usd"
    add_column :balances, :holding_amount_cents, :integer, default: 0

    add_index :balances, [:user_id, :merchant_account_id, :date, :currency, :holding_currency], unique: true, name: "unique_index"
    remove_index :balances, column: [:user_id, :merchant_account_id, :date]
  end

  def down
    add_index :balances, [:user_id, :merchant_account_id, :date], unique: true
    remove_index :balances, name: "unique_index"

    remove_column :balances, :holding_amount_cents
    remove_column :balances, :holding_currency
    remove_column :balances, :currency
  end
end
