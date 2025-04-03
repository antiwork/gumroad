# frozen_string_literal: true

class CreateLegacyPermalinks < ActiveRecord::Migration[6.1]
  def change
    create_table :legacy_permalinks do |t|
      t.string :permalink, null: false, index: { unique: true }
      t.references :product, null: false, index: true
    end
  end
end
