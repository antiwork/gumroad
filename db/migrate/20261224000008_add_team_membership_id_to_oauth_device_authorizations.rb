# frozen_string_literal: true

class AddTeamMembershipIdToOauthDeviceAuthorizations < ActiveRecord::Migration[8.1]
  # This branch renumbered the migration above main's schema version. A preview database that ran
  # the earlier number keeps it recorded, so the new number re-runs against a table that already
  # has the column.
  #
  # Rollback keeps the column while the original 20261223000008 is recorded. It does not check 20261224000004: main's
  # partner migrations now use that number, so it is recorded everywhere.
  SUPERSEDED_VERSION = "20261223000008"

  def up
    return if column_exists?(:oauth_device_authorizations, :team_membership_id)

    add_column :oauth_device_authorizations, :team_membership_id, :bigint
  end

  def down
    return unless column_exists?(:oauth_device_authorizations, :team_membership_id)
    return if select_value("SELECT 1 FROM schema_migrations WHERE version = #{quote(SUPERSEDED_VERSION)}")

    remove_column :oauth_device_authorizations, :team_membership_id, :bigint
  end
end
