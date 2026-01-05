# frozen_string_literal: true

class AddDefaultOfferCodeToLinks < ActiveRecord::Migration[7.1]
  def change
    # Note: Not using foreign_key constraint per project guidelines
    # The offer_codes table uses int for id, so we specify integer type
    add_column :links, :default_offer_code_id, :integer
    add_index :links, :default_offer_code_id
  end
end
