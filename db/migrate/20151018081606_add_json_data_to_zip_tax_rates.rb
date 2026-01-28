# frozen_string_literal: true

class AddJsonDataToZipTaxRates < ActiveRecord::Migration[4.2]
  def change
    add_column :zip_tax_rates, :json_data, :text
  end
end
