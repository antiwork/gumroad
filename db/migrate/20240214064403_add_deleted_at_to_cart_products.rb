# frozen_string_literal: true

class AddDeletedAtToCartProducts < ActiveRecord::Migration[7.0]
  def change
    change_table :cart_products, bulk: true do |t|
      t.datetime :deleted_at
      t.remove_index [:cart_id, :product_id], unique: true
      t.index [:cart_id, :product_id, :deleted_at], unique: true
    end
  end
end
