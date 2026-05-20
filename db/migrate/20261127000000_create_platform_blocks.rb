# frozen_string_literal: true

class CreatePlatformBlocks < ActiveRecord::Migration[7.1]
  def change
    create_table :platform_blocks do |t|
      t.string :object_type, null: false, limit: 50
      t.string :object_value, null: false, limit: 320
      t.datetime :blocked_at, precision: 6
      t.datetime :expires_at, precision: 6
      t.bigint :blocked_by

      t.timestamps precision: 6

      t.index [:object_type, :object_value], unique: true, name: "index_platform_blocks_on_type_and_value"
      t.index :object_value, name: "index_platform_blocks_on_value"
    end
  end
end
