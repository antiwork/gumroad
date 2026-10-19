# frozen_string_literal: true

class RenameShippingExclusionsLinkIdToProductId < ActiveRecord::Migration[8.1]
  # The first CreateShippingExclusions made an int link_id. A database that ran it keeps that column,
  # because CreateShippingExclusions now skips an existing table; every other database already has
  # product_id and skips this. Renumbered from 20261216170003 with the create. down is a no-op on
  # purpose: product_id is what the create makes, and reverting would break the model.
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
