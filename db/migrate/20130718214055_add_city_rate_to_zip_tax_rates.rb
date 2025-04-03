# frozen_string_literal: true

class AddCityRateToZipTaxRates < ActiveRecord::Migration
  def change
    rename_column :zip_tax_rates, :special_rate, :city_rate
    add_column :zip_tax_rates, :special_rate, :decimal, precision: 8, scale: 7
  end
end
