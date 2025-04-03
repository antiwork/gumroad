# frozen_string_literal: true

#
class AddRecentSalesCountToTaxonomyStats < ActiveRecord::Migration[7.1]
  def change
    add_column :taxonomy_stats, :recent_sales_count, :int, default: 0
  end
end
