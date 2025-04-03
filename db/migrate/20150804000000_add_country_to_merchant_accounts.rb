# frozen_string_literal: true

class AddCountryToMerchantAccounts < ActiveRecord::Migration
  def change
    add_column :merchant_accounts, :country, :string, default: "US"
  end
end
