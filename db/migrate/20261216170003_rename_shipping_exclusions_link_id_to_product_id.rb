# frozen_string_literal: true

class RenameShippingExclusionsLinkIdToProductId < ActiveRecord::Migration[8.1]
  # CreateShippingExclusions first shipped to this branch's preview database with an int link_id,
  # and that database still records its version, so it never sees the corrected create. Every
  # other database gets product_id from the create and skips this. No down: product_id is what
  # the create makes now.
  def up
    return unless column_exists?(:shipping_exclusions, :link_id)

    Alterity.disable do
      remove_index :shipping_exclusions, [:link_id, :country_code]
      rename_column :shipping_exclusions, :link_id, :product_id
      change_column :shipping_exclusions, :product_id, :bigint, null: false
      add_index :shipping_exclusions, [:product_id, :country_code], unique: true
    end
  end
end
