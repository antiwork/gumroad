# frozen_string_literal: true

class IndexOfferCodesOnLinkId < ActiveRecord::Migration[4.2]
  def up
    add_index :offer_codes, :link_id
  end

  def down
    remove_index :offer_codes, :link_id
  end
end
