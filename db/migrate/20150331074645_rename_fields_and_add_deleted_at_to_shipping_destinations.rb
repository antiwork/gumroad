# frozen_string_literal: true

class RenameFieldsAndAddDeletedAtToShippingDestinations < ActiveRecord::Migration
  def change
    add_column :shipping_destinations, :deleted_at, :datetime
    rename_column :shipping_destinations, :country_code2, :country_code
    rename_column :shipping_destinations, :standalone_rate_cents, :one_item_rate_cents
    rename_column :shipping_destinations, :combined_rate_cents, :multiple_items_rate_cents
  end
end
