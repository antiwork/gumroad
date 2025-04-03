# frozen_string_literal: true

class CreateProductFilesArchives < ActiveRecord::Migration
  def change
    create_table :product_files_archives do |t|
      t.timestamp :deleted_at
      t.belongs_to :link
      t.belongs_to :installment
      t.attachment :zip_archive_file
      t.string :product_files_archive_state

      t.timestamps
    end

    add_index :product_files_archives, :link_id
    add_index :product_files_archives, :installment_id

    create_table :product_files_files_archives do |t|
      t.references :product_file
      t.references :product_files_archive
    end

    add_index :product_files_files_archives, :product_files_archive_id
  end
end
