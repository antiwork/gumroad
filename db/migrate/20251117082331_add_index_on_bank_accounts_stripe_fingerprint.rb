# frozen_string_literal: true

class AddIndexOnBankAccountsStripeFingerprint < ActiveRecord::Migration[7.1]
  def change
    add_index :bank_accounts, :stripe_fingerprint
  end
end
