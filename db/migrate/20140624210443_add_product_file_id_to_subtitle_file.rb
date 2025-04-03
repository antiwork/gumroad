# frozen_string_literal: true

class AddProductFileIdToSubtitleFile < ActiveRecord::Migration
  def change
    add_column :subtitle_files, :product_file_id, :integer
    add_index :subtitle_files, :product_file_id
  end
end
