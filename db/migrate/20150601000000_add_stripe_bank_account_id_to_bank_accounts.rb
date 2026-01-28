# frozen_string_literal: true

class AddStripeBankAccountIdToBankAccounts < ActiveRecord::Migration[4.2]
  def change
    add_column :bank_accounts, :stripe_bank_account_id, :string
    add_column :bank_accounts, :stripe_fingerprint, :string
  end
end
