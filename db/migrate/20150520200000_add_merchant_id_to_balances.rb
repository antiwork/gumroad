# frozen_string_literal: true

class AddMerchantIdToBalances < ActiveRecord::Migration
  def up
    add_column :balances, :merchant_account_id, :integer, default: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id).id
    add_index :balances, [:user_id, :merchant_account_id, :date], unique: true
    remove_index :balances, column: [:user_id, :date]
  end

  def down
    remove_column :balances, :merchant_account_id
    remove_index :balances, column: [:user_id, :merchant_account_id, :date]
    add_index :balances, [:user_id, :date], unique: true
  end
end
