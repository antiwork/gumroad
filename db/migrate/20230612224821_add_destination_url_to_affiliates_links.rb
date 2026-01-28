# frozen_string_literal: true

class AddDestinationUrlToAffiliatesLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :affiliates_links, :destination_url, :string
  end
end
