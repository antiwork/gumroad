# frozen_string_literal: true

class AddCurrencyToMerchantAccounts < ActiveRecord::Migration[4.2]
  def change
    add_column :merchant_accounts, :currency, :string, default: "usd"
  end
end
