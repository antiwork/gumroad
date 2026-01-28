# frozen_string_literal: true

class AddNameAndLinkIdIndexToOfferCodes < ActiveRecord::Migration[4.2]
  def change
    add_index :offer_codes, [:name, :link_id]
  end
end
