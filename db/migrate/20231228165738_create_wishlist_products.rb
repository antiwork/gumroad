# frozen_string_literal: true

class CreateWishlistProducts < ActiveRecord::Migration[7.0]
  def change
    create_table :wishlist_products do |t|
      t.references :wishlist, null: false
      t.references :product, null: false
      t.references :variant
      t.string :recurrence
      t.integer :quantity, null: false
      t.boolean :rent, null: false

      t.timestamps
    end
  end
end
