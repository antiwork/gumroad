# frozen_string_literal: true

class CreateProductBuildSaves < ActiveRecord::Migration[8.1]
  def change
    create_table :product_build_saves do |t|
      t.bigint :purchase_id, null: false
      t.json :data, null: false
      t.integer :byte_size, null: false, default: 0
      t.timestamps

      t.index :purchase_id, unique: true
    end
  end
end
