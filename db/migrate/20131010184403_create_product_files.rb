# frozen_string_literal: true

class CreateProductFiles < ActiveRecord::Migration
  def change
    create_table :product_files do |t|
      t.integer :link_id
      t.string :url
      t.string :filetype
      t.string :filegroup
      t.integer :size
      t.integer :bitrate
      t.integer :framerate
      t.integer :pagelength
      t.integer :duration
      t.integer :width
      t.integer :height
      t.integer :flags, default: 0, null: false
      t.text :json_data
      t.datetime :deleted_at
      t.timestamps
    end

    add_index :product_files, :link_id
  end
end
