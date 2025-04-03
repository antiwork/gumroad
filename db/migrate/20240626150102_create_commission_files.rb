# frozen_string_literal: true

class CreateCommissionFiles < ActiveRecord::Migration[7.1]
  def change
    create_table :commission_files do |t|
      t.string :url, limit: 1024
      t.references :commission, null: false

      t.timestamps
    end
  end
end
