# frozen_string_literal: true

class AddExistingCustomerColumnsToOfferCodes < ActiveRecord::Migration[7.1]
  def change
    change_table :offer_codes, bulk: true do |t|
      t.boolean :existing_customers_only, default: false, null: false
      t.json :ownership_duration_tiers
    end
  end
end
