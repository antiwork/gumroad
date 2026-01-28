# frozen_string_literal: true

class CreateAssets < ActiveRecord::Migration[4.2]
  def change
    create_table :assets do |t|
      t.string :blob_key
      t.string :file_name
      t.integer :date
      t.string :unique_permalink
      t.string :file_type

      t.timestamps
    end
  end
end
