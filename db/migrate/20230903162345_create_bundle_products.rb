# frozen_string_literal: true

class CreateBundleProducts < ActiveRecord::Migration[7.0]
  def change
    create_table :bundle_products do |t|
      t.references :bundle, null: false
      t.references :product, null: false
      t.references :variant
      t.integer :quantity, null: false
      t.datetime :deleted_at

      t.timestamps
    end
  end
end
