# frozen_string_literal: true

class AddFolderIdToProductFiles < ActiveRecord::Migration[6.1]
  def change
    change_table :product_files do |t|
      t.bigint :folder_id
    end
  end
end
