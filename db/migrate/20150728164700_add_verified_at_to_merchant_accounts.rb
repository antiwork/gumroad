# frozen_string_literal: true

class AddVerifiedAtToMerchantAccounts < ActiveRecord::Migration[4.2]
  def change
    add_column :merchant_accounts, :charge_processor_verified_at, :datetime
  end
end
