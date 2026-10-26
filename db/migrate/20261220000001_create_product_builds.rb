# frozen_string_literal: true

class CreateProductBuilds < ActiveRecord::Migration[8.1]
  def change
    create_table :product_builds do |t|
      t.bigint :product_id, null: false
      t.string :public_id, limit: 21, null: false
      t.integer :number, null: false
      t.string :status, limit: 16, null: false, default: "uploaded"
      t.string :source_url, limit: 1024, null: false
      t.string :storage_key, limit: 1024, null: false
      t.bigint :byte_size, null: false
      t.bigint :product_file_id
      t.datetime :promoted_at
      t.timestamps

      t.index :public_id, unique: true
      t.index :storage_key, length: 191
      t.index [:product_id, :number], unique: true
      t.index [:product_id, :status]
      t.index [:product_id, :source_url], unique: true, length: { source_url: 191 }
    end
  end
end
