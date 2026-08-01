# frozen_string_literal: true

class CreateDashboardNavPromotions < ActiveRecord::Migration[7.1]
  # Renumbered from 20261206000021, which #6733's migration also claimed. Version 21 is still live
  # under that other migration, so it is recorded on every normally-migrated database and cannot be
  # read as evidence about this table. Ownership is only ambiguous where 21 was recorded by THIS
  # migration before the renumber — a branch database that ran #6766 pre-merge, which is why up
  # tolerates an existing table and down refuses to drop that one.
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
    return if table_predates_this_version?

    drop_table :dashboard_nav_promotions
  end

  private
    # True only where version 21 is recorded WITHOUT #6733's columns, i.e. it was this table's
    # migration under the old number. Dropping there would destroy rows this migration never
    # created; everywhere else 21 means #6733 and the table is this migration's to remove.
    def table_predates_this_version?
      superseded_version_applied? &&
        !column_exists?(:subscription_plan_changes, :notification_claim_id)
    end

    def superseded_version_applied?
      connection.select_value(
        ActiveRecord::Base.sanitize_sql_array(
          ["SELECT 1 FROM schema_migrations WHERE version = ? LIMIT 1", SUPERSEDED_VERSION]
        )
      ).present?
    end
end
