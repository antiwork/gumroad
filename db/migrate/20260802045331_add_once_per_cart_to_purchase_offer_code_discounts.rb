# frozen_string_literal: true

class AddOncePerCartToPurchaseOfferCodeDiscounts < ActiveRecord::Migration[7.1]
  def change
    change_table :purchase_offer_code_discounts, bulk: true do |table|
      table.boolean :once_per_cart, default: false, null: false
      table.integer :pre_discount_displayed_price_cents
    end
  end
end
