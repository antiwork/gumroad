# frozen_string_literal: true

class CreateBundleProductPurchases < ActiveRecord::Migration[7.0]
  def change
    create_table :bundle_product_purchases do |t|
      t.references :bundle_purchase, null: false
      t.references :product_purchase, null: false
      t.timestamps
    end
  end
end
