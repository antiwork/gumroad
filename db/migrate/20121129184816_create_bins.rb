# frozen_string_literal: true

class CreateBins < ActiveRecord::Migration
  def change
    create_table :bins do |t|
      t.string :card_bin
      t.string :issuing_bank
      t.string :card_type
      t.string :card_level
      t.string :iso_country_name
      t.string :iso_country_a2
      t.string :iso_country_a3
      t.integer :iso_country_number
      t.string :website
      t.string :phone_number
    end
    add_index :bins, :card_bin
  end
end
