# frozen_string_literal: true

class AddDeletedFromCdnIndexIndexes < ActiveRecord::Migration
  def change
    add_index :product_files, :deleted_from_cdn_at
    add_index :product_files_archives, :deleted_from_cdn_at
    add_index :transcoded_videos, :deleted_from_cdn_at
  end
end
