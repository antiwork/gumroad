# frozen_string_literal: true

class CreatePurchaseTaxjarInfos < ActiveRecord::Migration[7.0]
  def change
    create_table :purchase_taxjar_infos do |t|
      t.references :purchase, null: false
      t.decimal "combined_tax_rate", precision: 8, scale: 7
      t.decimal "county_tax_rate", precision: 8, scale: 7
      t.decimal "city_tax_rate", precision: 8, scale: 7
      t.decimal "state_tax_rate", precision: 8, scale: 7
      t.string "jurisdiction_state"
      t.string "jurisdiction_county"
      t.string "jurisdiction_city"
      t.timestamps
    end
  end
end
