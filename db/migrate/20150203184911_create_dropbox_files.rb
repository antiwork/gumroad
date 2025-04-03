# frozen_string_literal: true

class CreateDropboxFiles < ActiveRecord::Migration
  def change
    create_table :dropbox_files do |t|
      t.string :state
      t.string :dropbox_url
      t.datetime :expires_at
      t.datetime :deleted_at
      t.integer :user_id
      t.integer :product_file_id
      t.integer :link_id
      t.text :json_data
      t.string :s3_url

      t.timestamps
    end

    add_index :dropbox_files, :user_id
    add_index :dropbox_files, :product_file_id
    add_index :dropbox_files, :link_id
  end
end
