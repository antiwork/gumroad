# frozen_string_literal: true

class AddDestinationUrlToAffiliates < ActiveRecord::Migration
  def change
    add_column :affiliates, :destination_url, :string, limit: 2083
  end
end
