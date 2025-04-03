# frozen_string_literal: true

class MakeSubtitleFilesCdnDeletable < ActiveRecord::Migration[7.1]
  def up
    change_table :subtitle_files, bulk: true do |t|
      t.datetime :deleted_from_cdn_at
      t.index :url
      t.index :deleted_at

      t.change :id, :bigint, null: false, auto_increment: true
      t.change :product_file_id, :bigint
      t.change :deleted_at, :datetime, limit: 6
      t.change :created_at, :datetime, limit: 6
      t.change :updated_at, :datetime, limit: 6
    end
  end

  def down
    change_table :subtitle_files, bulk: true do |t|
      t.remove :deleted_from_cdn_at
      t.remove_index :url
      t.remove_index :deleted_at

      t.change :id, :int, null: false, auto_increment: true
      t.change :product_file_id, :int
      t.change :deleted_at, :datetime, precision: nil
      t.change :created_at, :datetime, precision: nil
      t.change :updated_at, :datetime, precision: nil
    end
  end
end
