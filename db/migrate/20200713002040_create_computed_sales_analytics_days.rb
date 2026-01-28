# frozen_string_literal: true

class CreateComputedSalesAnalyticsDays < ActiveRecord::Migration[4.2]
  def change
    create_table :computed_sales_analytics_days do |t|
      t.string :key, null: false, index: { unique: true }
      t.text :data, limit: 10.megabytes # mediumtext
      t.timestamps null: false
    end
  end
end
