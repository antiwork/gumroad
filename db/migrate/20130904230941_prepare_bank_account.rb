# frozen_string_literal: true

class PrepareBankAccount < ActiveRecord::Migration
  def up
    rename_table :ach_accounts, :bank_accounts
    add_column :bank_accounts, :type, :string, default: "AchAccount"
    add_column :bank_accounts, :branch_code, :string
    rename_column :bank_accounts, :routing_number, :bank_number
    rename_column :payments, :ach_account_id, :bank_account_id
    add_column :payments, :amount_cents_in_local_currency, :integer
  end

  def down
    rename_table :bank_accounts, :ach_accounts
    remove_column :ach_accounst, :type
    remove_column :ach_accounst, :branch_code
    rename_column :ach_accounts, :bank_number, :routing_number
    rename_column :payments, :bank_account_id, :ach_account_id
    remove_column :payments, :amount_cents_in_local_currency
  end
end
