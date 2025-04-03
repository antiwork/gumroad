# frozen_string_literal: true

class CreateSellerProfileSections < ActiveRecord::Migration[7.0]
  def change
    create_table :seller_profile_sections do |t|
      t.references :seller, index: true, null: false
      t.string :header
      t.text :shown_products, null: false
      t.boolean :show_filters, null: false
      t.string :default_product_sort, null: false
      t.timestamps
    end
  end
end
