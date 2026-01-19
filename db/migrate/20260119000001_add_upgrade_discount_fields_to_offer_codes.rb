# frozen_string_literal: true

class AddUpgradeDiscountFieldsToOfferCodes < ActiveRecord::Migration[7.1]
  def change
    change_table :offer_codes, bulk: true do |t|
      t.json :required_product_ids
      t.json :minimum_quantity_discount_tiers
    end
  end
end
