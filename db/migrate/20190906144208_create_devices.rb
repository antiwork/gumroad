# frozen_string_literal: true

class CreateDevices < ActiveRecord::Migration
  def change
    create_table :devices do |t|
      t.string :token, null: false, limit: 255
      t.string :app_version, limit: 255
      t.string :device_type, null: false, default: "ios", limit: 255

      t.references :user, foreign_key: { on_delete: :cascade }, null: false, index: true

      t.timestamps null: false
    end

    add_index :devices, :token, unique: true
  end
end
