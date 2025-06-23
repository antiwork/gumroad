# frozen_string_literal: true

class AddCustomFeesToPurchases < ActiveRecord::Migration[7.1]
  def change
    change_table :purchases, bulk: true do |t|
      t.decimal :custom_direct_fee_percentage, precision: 5, scale: 2, default: nil
      t.decimal :custom_discover_fee_percentage, precision: 5, scale: 2, default: nil
    end
  end
end
