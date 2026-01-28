# frozen_string_literal: true

class AddDeletedFromCdnAtToProductFilesArchive < ActiveRecord::Migration[4.2]
  def change
    add_column :product_files_archives, :deleted_from_cdn_at, :datetime
  end
end
