# frozen_string_literal: true

class RemoveUnusedColumnsFromPayments < ActiveRecord::Migration[6.1]
  def up
    change_table :payments, bulk: true do |t|
      t.remove :status_data
      t.remove :unique_id
      t.remove :local_currency
      t.change :id, :bigint, null: false, unique: true, auto_increment: true
      t.change :user_id, :bigint
      t.change :bank_account_id, :bigint
    end
  end

  def down
    change_table :payments, bulk: true do |t|
      t.text :status_data
      t.string :unique_id
      t.string :local_currency
      t.change :id, :integer, null: false, unique: true, auto_increment: true
      t.change :user_id, :integer
      t.change :bank_account_id, :integer
    end
  end
end
