# frozen_string_literal: true

class IndexMediaLocationsProductIdUpdatedAt < ActiveRecord::Migration[4.2]
  def change
    add_index :media_locations, [:product_id, :updated_at]
  end
end
