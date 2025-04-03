# frozen_string_literal: true

class ChangeProductFilesArchivesJsonDataType < ActiveRecord::Migration[7.0]
  def up
    change_column :product_files_archives, :json_data, :mediumtext
  end

  def down
    change_column :product_files_archives, :json_data, :text
  end
end
