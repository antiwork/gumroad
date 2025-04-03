# frozen_string_literal: true

class RemoveDateUniquenessConstraintFromBalances < ActiveRecord::Migration[7.1]
  def up
    change_table :balances, bulk: true do |t|
      t.index [:user_id, :merchant_account_id, :date], name: "index_on_user_merchant_account_date"
      t.remove_index name: "unique_index"
    end
  end

  def down
    change_table :balances, bulk: true do |t|
      t.index [:user_id, :merchant_account_id, :date, :currency, :holding_currency], unique: true, name: "unique_index"
      t.remove_index name: "index_on_user_merchant_account_date"
    end
  end
end
