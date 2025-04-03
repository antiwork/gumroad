# frozen_string_literal: true

class CreateZipTaxRates < ActiveRecord::Migration
  def change
    create_table :zip_tax_rates do |t|
      t.decimal :combined_rate, precision: 8, scale: 7
      t.decimal :county_rate,  precision: 8, scale: 7
      t.decimal :special_rate, precision: 8, scale: 7
      t.string :state
      t.decimal :state_rate, precision: 8, scale: 7
      t.string :tax_region_code
      t.string :tax_region_name
      t.string :zip_code

      t.timestamps
    end
    add_index :zip_tax_rates, :zip_code
  end
end
