# frozen_string_literal: true

class CreateShippingExclusions < ActiveRecord::Migration[8.1]
  # Renumbered after main took the superseded version, so up skips a table an older run created and
  # down cannot tell who created it: down keeps the table and its rows whenever that version is
  # recorded, which is every database on main, leaving schema in place instead of losing data.
  SUPERSEDED_VERSION = "20261216170002"

  def up
    create_table :shipping_exclusions, if_not_exists: true do |t|
      t.bigint :product_id, null: false
      t.string :country_code, null: false
      t.timestamps

      t.index [:product_id, :country_code], unique: true
    end
  end

  def down
    return unless table_exists?(:shipping_exclusions)
    return if superseded_version_applied?

    drop_table :shipping_exclusions
  end

  private
    def superseded_version_applied?
      connection.select_value(
        ActiveRecord::Base.sanitize_sql_array(
          ["SELECT 1 FROM schema_migrations WHERE version = ? LIMIT 1", SUPERSEDED_VERSION]
        )
      ).present?
    end
end
