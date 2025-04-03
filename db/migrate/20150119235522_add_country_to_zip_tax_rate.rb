# frozen_string_literal: true

class AddCountryToZipTaxRate < ActiveRecord::Migration
  def change
    add_column :zip_tax_rates, :country, :string, null: false
  end
end
