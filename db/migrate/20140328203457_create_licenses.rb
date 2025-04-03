# frozen_string_literal: true

class CreateLicenses < ActiveRecord::Migration
  def change
    create_table :licenses, options: "DEFAULT CHARACTER SET=utf8 COLLATE=utf8_general_ci" do |t|
      t.integer :link_id
      t.integer :purchase_id
      t.string :serial
      t.datetime :trial_expires_at
      t.integer :uses, default: 0
      t.string :json_data
      t.datetime :deleted_at
      t.integer :flags

      t.timestamps
    end

    add_index :licenses, :link_id
    add_index :licenses, :purchase_id
    add_index :licenses, :serial, unique: true
  end
end
