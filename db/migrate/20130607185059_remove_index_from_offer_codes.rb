# frozen_string_literal: true

class RemoveIndexFromOfferCodes < ActiveRecord::Migration[4.2]
  def change
    remove_index :offer_codes, name: "index_offer_codes_on_link_id_and_name"
  end
end
