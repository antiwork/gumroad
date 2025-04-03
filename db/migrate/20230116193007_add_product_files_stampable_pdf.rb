# frozen_string_literal: true

class AddProductFilesStampablePdf < ActiveRecord::Migration[7.0]
  def change
    add_column :product_files, :stampable_pdf, :boolean
  end
end
