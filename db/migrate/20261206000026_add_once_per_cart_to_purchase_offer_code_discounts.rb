# frozen_string_literal: true

class AddOncePerCartToPurchaseOfferCodeDiscounts < ActiveRecord::Migration[7.1]
  # The original version ran on earlier branch databases, so both directions must be idempotent.
  SUPERSEDED_VERSION = "20260802045331"

  def up
    add_once_per_cart = !column_exists?(:purchase_offer_code_discounts, :once_per_cart)
    add_pre_discount_price = !column_exists?(:purchase_offer_code_discounts, :pre_discount_displayed_price_cents)
    return unless add_once_per_cart || add_pre_discount_price

    change_table :purchase_offer_code_discounts, bulk: true do |table|
      table.boolean :once_per_cart, default: false, null: false if add_once_per_cart
      table.integer :pre_discount_displayed_price_cents if add_pre_discount_price
    end
  end

  def down
    return if superseded_version_applied?

    change_table :purchase_offer_code_discounts, bulk: true do |table|
      table.remove :once_per_cart if column_exists?(:purchase_offer_code_discounts, :once_per_cart)
      table.remove :pre_discount_displayed_price_cents if column_exists?(:purchase_offer_code_discounts, :pre_discount_displayed_price_cents)
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
