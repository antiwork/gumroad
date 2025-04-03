# frozen_string_literal: true

class AddQuantityAndMerchantIdToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :quantity, :integer, default: 1, null: false
    add_column :purchases, :merchant_account_id, :integer
  end
end
