# frozen_string_literal: true

class AddStripeBankAccountIdToBankAccounts < ActiveRecord::Migration
  def change
    add_column :bank_accounts, :stripe_bank_account_id, :string
    add_column :bank_accounts, :stripe_fingerprint, :string
  end
end
