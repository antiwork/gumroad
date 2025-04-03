# frozen_string_literal: true

class AddDigestToProductFilesArchive < ActiveRecord::Migration[7.0]
  def change
    add_column :product_files_archives, :digest, :string
  end
end
