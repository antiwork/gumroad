# frozen_string_literal: true

class CreateProductPermalinkRedirects < ActiveRecord::Migration[7.1]
  def change
    create_table :product_permalink_redirects do |t|
      t.belongs_to :product, null: false
      t.belongs_to :seller, null: false, index: false
      t.string :permalink, null: false
      t.timestamps

      t.index [:seller_id, :permalink], unique: true, name: "idx_product_permalink_redirects_on_seller_and_permalink"
    end
  end
end
