# frozen_string_literal: true

class AddDefaultOfferCodeToLinks < ActiveRecord::Migration[7.1]
  def change
    add_reference :links, :default_offer_code, foreign_key: { to_table: :offer_codes }, index: true
  end
end

