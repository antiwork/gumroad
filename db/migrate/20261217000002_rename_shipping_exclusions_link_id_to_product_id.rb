# frozen_string_literal: true

class RenameShippingExclusionsLinkIdToProductId < ActiveRecord::Migration[8.1]
  # Only the first CreateShippingExclusions made an int link_id. down is a no-op because reverting
  # would rename a table created with product_id, or narrow ids that grew past int after the upgrade.
  def up
    return unless column_exists?(:shipping_exclusions, :link_id)

    Alterity.disable do
      remove_index :shipping_exclusions, [:link_id, :country_code]
      rename_column :shipping_exclusions, :link_id, :product_id
      change_column :shipping_exclusions, :product_id, :bigint, null: false
      add_index :shipping_exclusions, [:product_id, :country_code], unique: true
    end
  end

  def down
  end
end
