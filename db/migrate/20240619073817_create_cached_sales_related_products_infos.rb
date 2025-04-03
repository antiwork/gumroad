# frozen_string_literal: true

class CreateCachedSalesRelatedProductsInfos < ActiveRecord::Migration[7.1]
  def change
    create_table :cached_sales_related_products_infos do |t|
      t.bigint :product_id, null: false, index: { unique: true }
      t.json :counts

      t.timestamps
    end
  end
end
