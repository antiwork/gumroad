# frozen_string_literal: true

class AddTotalUsdCentsToProductCachedValue < ActiveRecord::Migration[7.1]
  def change
    add_column :product_cached_values, :total_usd_cents, :bigint, default: 0
  end
end
