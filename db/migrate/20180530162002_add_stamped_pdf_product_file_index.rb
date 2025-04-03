# frozen_string_literal: true

class AddStampedPdfProductFileIndex < ActiveRecord::Migration
  def change
    add_index :stamped_pdfs, :product_file_id
  end
end
