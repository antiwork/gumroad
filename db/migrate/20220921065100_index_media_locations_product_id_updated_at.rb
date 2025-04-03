# frozen_string_literal: true

class IndexMediaLocationsProductIdUpdatedAt < ActiveRecord::Migration[6.1]
  def change
    add_index :media_locations, [:product_id, :updated_at]
  end
end
