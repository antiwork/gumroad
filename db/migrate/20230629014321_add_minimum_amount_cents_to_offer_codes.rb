# frozen_string_literal: true

class AddMinimumAmountCentsToOfferCodes < ActiveRecord::Migration[7.0]
  def change
    change_table :offer_codes, bulk: true do |t|
      t.integer :minimum_amount_cents
    end
  end
end
