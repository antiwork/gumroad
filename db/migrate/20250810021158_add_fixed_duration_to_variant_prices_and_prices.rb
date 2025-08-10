# frozen_string_literal: true

class AddFixedDurationToVariantPricesAndPrices < ActiveRecord::Migration[7.1]
  def change
    add_column :prices, :fixed_duration_months, :integer
    add_column :variant_prices, :fixed_duration_months, :integer
    add_column :cart_products, :fixed_duration_months, :integer

    add_index :prices, :fixed_duration_months
    add_index :variant_prices, :fixed_duration_months
    add_index :cart_products, :fixed_duration_months
  end
end