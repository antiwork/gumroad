# frozen_string_literal: true

class DropJsonDataFromProductFilesArchive < ActiveRecord::Migration[7.0]
  def change
    remove_column :product_files_archives, :json_data, :text, size: :medium
  end
end
