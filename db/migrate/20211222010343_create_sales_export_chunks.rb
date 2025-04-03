# frozen_string_literal: true

class CreateSalesExportChunks < ActiveRecord::Migration[6.1]
  def change
    create_table :sales_export_chunks do |t|
      t.bigint :export_id, null: false, index: true
      t.longtext :purchase_ids
      t.text :custom_fields
      t.longtext :purchases_data
      t.boolean :processed, default: false, null: false
      t.string :revision
      t.timestamps
    end
  end
end
