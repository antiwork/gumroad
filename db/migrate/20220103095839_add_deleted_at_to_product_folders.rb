# frozen_string_literal: true

class AddDeletedAtToProductFolders < ActiveRecord::Migration[6.1]
  def change
    add_column :product_folders, :deleted_at, :datetime
  end
end
