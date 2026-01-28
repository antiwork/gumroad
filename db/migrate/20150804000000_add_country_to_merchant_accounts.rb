# frozen_string_literal: true

class AddCountryToMerchantAccounts < ActiveRecord::Migration[4.2]
  def change
    add_column :merchant_accounts, :country, :string, default: "US"
  end
end
