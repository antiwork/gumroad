# frozen_string_literal: true

class AddJsonDataToProductFilesArchives < ActiveRecord::Migration[6.1]
  def change
    add_column :product_files_archives, :json_data, :text
  end
end
