# frozen_string_literal: true

class CreateStampedPdfs < ActiveRecord::Migration
  def change
    create_table :stamped_pdfs do |t|
      t.integer :url_redirect_id
      t.integer :product_file_id
      t.string :url
      t.timestamps
    end

    add_index :stamped_pdfs, :url_redirect_id
  end
end
