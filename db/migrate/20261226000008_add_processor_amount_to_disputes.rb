# frozen_string_literal: true

class AddProcessorAmountToDisputes < ActiveRecord::Migration[8.1]
  # This migration first ran as 20261226000007, and this branch's preview database still records that
  # number. main now uses it for AddTestingAndQaTaxonomy, so it is recorded nearly everywhere, and down
  # keeps the columns there, as CONTRIBUTING.md asks for a renumbered migration.
  SUPERSEDED_VERSION = "20261226000007"
  COLUMNS = { processor_amount_cents: :bigint, processor_currency: :string }.freeze

  # change_table bulk: true rejects if_not_exists/if_exists, so the guards pick the columns up front
  # and the table still gets one ALTER.
  def up
    missing = COLUMNS.reject { |name, _| column_exists?(:disputes, name) }
    return if missing.empty?

    change_table :disputes, bulk: true do |t|
      missing.each { |name, type| t.column name, type }
    end
  end

  def down
    return if select_value("SELECT 1 FROM schema_migrations WHERE version = #{connection.quote(SUPERSEDED_VERSION)}").present?

    present = COLUMNS.keys.select { |name| column_exists?(:disputes, name) }
    return if present.empty?

    change_table :disputes, bulk: true do |t|
      t.remove(*present)
    end
  end
end
