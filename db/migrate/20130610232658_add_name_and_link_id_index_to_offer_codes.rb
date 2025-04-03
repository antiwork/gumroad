# frozen_string_literal: true

class AddNameAndLinkIdIndexToOfferCodes < ActiveRecord::Migration
  def change
    add_index :offer_codes, [:name, :link_id]
  end
end
