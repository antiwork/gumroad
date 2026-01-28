# frozen_string_literal: true

class AddRelationshipToMerchantAccounts < ActiveRecord::Migration[4.2]
  def change
    add_column :merchant_accounts, :relationship, :string
  end
end
