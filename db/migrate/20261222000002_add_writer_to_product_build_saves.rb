# frozen_string_literal: true

class AddWriterToProductBuildSaves < ActiveRecord::Migration[8.1]
  def change
    change_table :product_build_saves, bulk: true do |t|
      t.string :writer_id, limit: 32
      t.integer :writer_sequence
    end
  end
end
