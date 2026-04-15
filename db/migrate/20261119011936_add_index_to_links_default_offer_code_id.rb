# frozen_string_literal: true

class AddIndexToLinksDefaultOfferCodeId < ActiveRecord::Migration[7.1]
  def change
    add_index :links, :default_offer_code_id
  end
end
