# frozen_string_literal: true

class AddIndexToOfferCodes < ActiveRecord::Migration[4.2]
  def change
    add_index :offer_codes, [:link_id, :name], unique: true
  end
end
