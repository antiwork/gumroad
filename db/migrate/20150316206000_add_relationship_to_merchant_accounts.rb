# frozen_string_literal: true

class AddRelationshipToMerchantAccounts < ActiveRecord::Migration
  def change
    add_column :merchant_accounts, :relationship, :string
  end
end
