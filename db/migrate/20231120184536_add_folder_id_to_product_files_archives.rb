# frozen_string_literal: true

class AddFolderIdToProductFilesArchives < ActiveRecord::Migration[7.0]
  def change
    change_table :product_files_archives, bulk: true do |t|
      t.string :folder_id
      t.index :folder_id
    end
  end
end
