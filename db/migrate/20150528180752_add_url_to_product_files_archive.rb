# frozen_string_literal: true

class AddUrlToProductFilesArchive < ActiveRecord::Migration
  def change
    add_column :product_files_archives, :url, :string
    remove_column :product_files_archives, :zip_archive_file_file_name
    remove_column :product_files_archives, :zip_archive_file_content_type
    remove_column :product_files_archives, :zip_archive_file_file_size
    remove_column :product_files_archives, :zip_archive_file_updated_at
  end
end
