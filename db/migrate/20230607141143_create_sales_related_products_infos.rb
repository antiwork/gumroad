# frozen_string_literal: true

class CreateSalesRelatedProductsInfos < ActiveRecord::Migration[7.0]
  def change
    create_table :sales_related_products_infos do |t|
      t.bigint :smaller_product_id, null: false
      t.bigint :larger_product_id, null: false
      t.integer :sales_count, default: 0, null: false
      t.timestamps

      t.index [:smaller_product_id, :larger_product_id], name: :index_smaller_and_larger_product_ids, unique: true
      t.index [:smaller_product_id, :sales_count], name: :index_smaller_product_id_and_sales_count
      t.index [:larger_product_id, :sales_count], name: :index_larger_product_id_and_sales_count
    end
  end
end
