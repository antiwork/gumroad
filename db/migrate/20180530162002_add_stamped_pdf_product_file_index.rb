# frozen_string_literal: true

class AddStampedPdfProductFileIndex < ActiveRecord::Migration[4.2]
  def change
    add_index :stamped_pdfs, :product_file_id
  end
end
