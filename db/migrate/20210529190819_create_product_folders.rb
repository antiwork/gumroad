# frozen_string_literal: true

class CreateProductFolders < ActiveRecord::Migration[6.1]
  def change
    create_table :product_folders do |t|
      t.bigint :product_id, index: true
      t.string :name
      t.integer :position
      t.timestamps
    end
  end
end
