# frozen_string_literal: true

class AddCountryStateIndexToZipTaxRates < ActiveRecord::Migration[8.1]
  def change
    # deleted_at comes before state because almost every row is soft-deleted. On (country, state)
    # alone, MySQL still prefers the ORDER BY id primary-key scan for countries with many deleted rows.
    #
    # if_not_exists: this branch's preview database ran the migration as 20261216160001 before it
    # was renumbered.
    add_index :zip_tax_rates, [:country, :deleted_at, :state], if_not_exists: true
  end
end
