# frozen_string_literal: true

class CreateDashboardNavPromotions < ActiveRecord::Migration[7.1]
  # Renumbered from 20261206000021, which #6733's migration had already taken — two branches picked
  # the same next number and both merged, so every branch's suite died in maintain_test_schema!.
  # Where the old version is already recorded, db:migrate now runs this against a database that has
  # the table: up leaves it alone, and down refuses to drop a table this migration never created.
  # That is why this is an explicit up/down pair rather than a reversible change.
  SUPERSEDED_VERSION = "20261206000021"

  def up
    create_table :dashboard_nav_promotions, if_not_exists: true do |t|
      t.bigint :user_id, null: false
      t.string :nav_item, null: false

      t.timestamps

      t.index [:user_id, :nav_item], unique: true
    end
  end

  def down
    return unless table_exists?(:dashboard_nav_promotions)
    # The version numbers alone cannot prove ownership — under the collision, 21 may instead be
    # #6733's column migration — so this errs towards keeping the table. A rollback that leaves an
    # unused table behind costs nothing; one that drops it loses every promotion row.
    return if superseded_version_applied?

    drop_table :dashboard_nav_promotions
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
