# frozen_string_literal: true

class AddCountryStateIndexToZipTaxRates < ActiveRecord::Migration[8.1]
  def change
    # deleted_at comes before state because almost every row is soft-deleted. On (country, state)
    # alone, MySQL still prefers the ORDER BY id primary-key scan for countries with many deleted rows.
    add_index :zip_tax_rates, [:country, :deleted_at, :state]
  end
end
