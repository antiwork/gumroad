# frozen_string_literal: true

class CreateProductSalesHolds < ActiveRecord::Migration[8.1]
  def change
    create_table :product_sales_holds do |t|
      t.string :external_id, limit: 21, null: false
      t.bigint :product_id, null: false
      t.bigint :held_by_id, null: false
      t.boolean :unpublished_listing, null: false, default: false
      t.datetime :released_at
      t.bigint :released_by_id
      t.timestamps

      t.index :external_id, unique: true
      t.index [:product_id, :released_at]
    end
  end
end
