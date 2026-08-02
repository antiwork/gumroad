# frozen_string_literal: true

class AddOncePerCartAllocationIdToPurchaseOfferCodeDiscounts < ActiveRecord::Migration[7.1]
  # Earlier versions ran on branch databases, so both directions must be idempotent.
  SUPERSEDED_VERSION = "20260802135200"

  def up
    add_allocation_id = !column_exists?(:purchase_offer_code_discounts, :once_per_cart_allocation_id)
    add_allocation_index = !index_exists?(:purchase_offer_code_discounts, :once_per_cart_allocation_id, name: :index_poc_discounts_on_once_per_cart_allocation_id)
    return unless add_allocation_id || add_allocation_index

    change_table :purchase_offer_code_discounts, bulk: true do |table|
      table.string :once_per_cart_allocation_id if add_allocation_id
      table.index :once_per_cart_allocation_id, name: :index_poc_discounts_on_once_per_cart_allocation_id if add_allocation_index
    end
  end

  def down
    return if superseded_version_applied?

    change_table :purchase_offer_code_discounts, bulk: true do |table|
      if index_exists?(:purchase_offer_code_discounts, :once_per_cart_allocation_id, name: :index_poc_discounts_on_once_per_cart_allocation_id)
        table.remove_index name: :index_poc_discounts_on_once_per_cart_allocation_id
      end
      table.remove :once_per_cart_allocation_id if column_exists?(:purchase_offer_code_discounts, :once_per_cart_allocation_id)
    end
  end

  private
    def superseded_version_applied?
      connection.select_value(
        ActiveRecord::Base.sanitize_sql_array(
          ["SELECT 1 FROM schema_migrations WHERE version = ? LIMIT 1", SUPERSEDED_VERSION]
        )
      ).present?
    end
end
