# frozen_string_literal: true

class AddIndexOnProductFilesUrl < ActiveRecord::Migration[7.1]
  def change
    add_index :product_files, :url
  end
end
