# frozen_string_literal: true

class AddSalesCountForInventoryCache < ActiveRecord::Migration[7.1]
  def change
    add_column :base_variants, :sales_count_for_inventory_cache, :integer, default: 0, null: false
    add_column :links, :sales_count_for_inventory_cache, :integer, default: 0, null: false
  end
end
