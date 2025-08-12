# frozen_string_literal: true

class CreateChapterFiles < ActiveRecord::Migration[7.1]
  def change
    create_table :chapter_files do |t|
      t.string :url, limit: 1024
      t.string :title
      t.references :product_file, null: false, foreign_key: true
      t.datetime :deleted_at
      t.integer :size
      t.datetime :deleted_from_cdn_at

      t.timestamps
    end

    add_index :chapter_files, :deleted_at
    add_index :chapter_files, :product_file_id
  end
end
