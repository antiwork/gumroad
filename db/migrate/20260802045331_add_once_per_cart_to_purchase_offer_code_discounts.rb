# frozen_string_literal: true

class AddOncePerCartToPurchaseOfferCodeDiscounts < ActiveRecord::Migration[7.1]
  def change
    add_column :purchase_offer_code_discounts, :once_per_cart, :boolean, default: false, null: false
  end
end
