# frozen_string_literal: true

class ChangeProductFolderName < ActiveRecord::Migration[6.1]
  def up
    change_column :product_folders, :name, :string, null: false
  end

  def down
    change_column :product_folders, :name, :string, null: true
  end
end
