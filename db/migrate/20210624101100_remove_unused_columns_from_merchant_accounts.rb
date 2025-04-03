# frozen_string_literal: true

class RemoveUnusedColumnsFromMerchantAccounts < ActiveRecord::Migration[6.1]
  def up
    change_table :merchant_accounts, bulk: true do |t|
      t.remove :relationship
      t.change :id, :bigint, null: false, unique: true, auto_increment: true
      t.change :user_id, :bigint
    end
  end

  def down
    change_table :merchant_accounts, bulk: true do |t|
      t.string :relationship
      t.change :id, :integer, null: false, unique: true, auto_increment: true
      t.change :user_id, :integer
    end
  end
end
