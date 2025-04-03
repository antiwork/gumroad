# frozen_string_literal: true

class CreateUpsells < ActiveRecord::Migration[7.0]
  def change
    create_table :upsells do |t|
      t.references :seller, null: false
      t.references :offered_product, null: false
      t.references :offered_variant
      t.references :offer_code
      t.string :name, null: false
      t.boolean :cross_sell, null: false
      t.string :text
      t.text :description
      t.datetime :deleted_at

      t.timestamps
    end
  end
end
