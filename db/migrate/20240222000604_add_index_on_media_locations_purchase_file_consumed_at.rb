# frozen_string_literal: true

class AddIndexOnMediaLocationsPurchaseFileConsumedAt < ActiveRecord::Migration[7.0]
  def change
    add_index :media_locations, [:purchase_id, :product_file_id, :consumed_at], name: "index_media_locations_on_purchase_id_product_file_id_consumed_at"
  end
end
