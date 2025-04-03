# frozen_string_literal: true

class AddIndexToOfferCodes < ActiveRecord::Migration
  def change
    add_index :offer_codes, [:link_id, :name], unique: true
  end
end
