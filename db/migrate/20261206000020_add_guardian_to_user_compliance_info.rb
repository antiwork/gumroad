# frozen_string_literal: true

class AddGuardianToUserComplianceInfo < ActiveRecord::Migration[7.1]
  # Renumbered from 20261206000016 after that version was already recorded in production's
  # schema_migrations, so db:migrate now runs this migration against databases that already have
  # the column. Both directions have to cope with that: up leaves the existing column alone, and
  # down must not remove a column this migration never created.
  SUPERSEDED_VERSION = "20261206000016"

  def up
    return if column_exists?(:user_compliance_info, :guardian_id)

    change_table :user_compliance_info, bulk: true do |t|
      t.bigint :guardian_id
      t.index :guardian_id
    end
  end

  def down
    return unless column_exists?(:user_compliance_info, :guardian_id)
    # Where the old version is still recorded, the column and every guardian association stored in
    # it belong to that migration, and rolling this one back must leave them in place. The version
    # numbers alone cannot prove ownership — the collision this branch fixes means 16 may instead
    # have been the presentment migration — so this errs towards keeping the column. A rollback
    # that leaves a nullable column behind costs nothing; one that drops it loses data.
    return if superseded_version_applied?

    remove_column :user_compliance_info, :guardian_id
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
