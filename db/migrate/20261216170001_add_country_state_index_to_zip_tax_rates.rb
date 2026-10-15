# frozen_string_literal: true

class AddCountryStateIndexToZipTaxRates < ActiveRecord::Migration[8.1]
  # deleted_at comes before state because almost every row is soft-deleted. On (country, state)
  # alone, MySQL still prefers the ORDER BY id primary-key scan for countries with many deleted rows.
  COLUMNS = %i[country deleted_at state].freeze

  SUPERSEDED_VERSION = "20261216160001"

  def up
    # Branch databases may have applied this index before the migration was renumbered.
    return if index_exists?(:zip_tax_rates, COLUMNS)

    add_index :zip_tax_rates, COLUMNS
  end

  def down
    return if connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(
        ["SELECT 1 FROM schema_migrations WHERE version = ? LIMIT 1", SUPERSEDED_VERSION]
      )
    ).present?
    return unless index_exists?(:zip_tax_rates, COLUMNS)

    remove_index :zip_tax_rates, COLUMNS
  end
end
