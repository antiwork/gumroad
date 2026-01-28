# frozen_string_literal: true

class AddCountryToZipTaxRate < ActiveRecord::Migration[4.2]
  def change
    add_column :zip_tax_rates, :country, :string, null: false
  end
end
