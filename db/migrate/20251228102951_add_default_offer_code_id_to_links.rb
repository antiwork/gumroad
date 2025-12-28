# frozen_string_literal: true

class AddDefaultOfferCodeIdToLinks < ActiveRecord::Migration[7.1]
  def change
    add_reference :links, :default_offer_code, type: :integer, foreign_key: { to_table: :offer_codes }, null: true, index: true
  end
end
