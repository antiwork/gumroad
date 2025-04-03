# frozen_string_literal: true

class AddValidityColumnsToOfferCodes < ActiveRecord::Migration[7.0]
  def change
    change_table :offer_codes, bulk: true do |t|
      t.datetime :valid_at
      t.datetime :expires_at
    end
  end
end
