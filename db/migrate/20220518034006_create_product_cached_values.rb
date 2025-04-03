# frozen_string_literal: true

class CreateProductCachedValues < ActiveRecord::Migration[6.1]
  def change
    create_table :product_cached_values do |t|
      t.bigint :product_id, null: false, index: true
      t.boolean :expired, default: false, null: false, index: true
      t.integer :successful_sales_count
      t.integer :remaining_for_sale_count
      t.decimal :monthly_recurring_revenue, precision: 10, scale: 2
      t.decimal :revenue_pending, precision: 10, scale: 2
      t.timestamps
    end
  end
end
