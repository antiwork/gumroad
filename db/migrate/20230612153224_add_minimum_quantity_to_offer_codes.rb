# frozen_string_literal: true

class AddMinimumQuantityToOfferCodes < ActiveRecord::Migration[7.0]
  def change
    change_table :offer_codes, bulk: true do |t|
      t.integer "minimum_quantity"
    end
  end
end
