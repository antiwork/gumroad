# frozen_string_literal: true

class AddDefaultOfferCodeIdToLinks < ActiveRecord::Migration[7.1]
  def change
    add_column :links, :default_offer_code_id, :bigint
  end
end
