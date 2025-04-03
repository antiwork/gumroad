# frozen_string_literal: true

class AddDurationInMonthsToOfferCodes < ActiveRecord::Migration[7.0]
  def change
    change_table :offer_codes, bulk: true do |t|
      t.integer :duration_in_months
    end
  end
end
