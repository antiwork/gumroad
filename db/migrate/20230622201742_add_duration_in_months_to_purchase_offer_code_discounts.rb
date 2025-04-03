# frozen_string_literal: true

class AddDurationInMonthsToPurchaseOfferCodeDiscounts < ActiveRecord::Migration[7.0]
  def change
    change_table :purchase_offer_code_discounts, bulk: true do |t|
      t.integer :duration_in_months
    end
  end
end
