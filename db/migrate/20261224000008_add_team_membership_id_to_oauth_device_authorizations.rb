# frozen_string_literal: true

class AddTeamMembershipIdToOauthDeviceAuthorizations < ActiveRecord::Migration[8.1]
  # This branch renumbered the migration above main's schema version. A preview database that ran
  # the earlier number keeps it recorded, so the new number re-runs against a table that already
  # has the column.
  def up
    return if column_exists?(:oauth_device_authorizations, :team_membership_id)

    add_column :oauth_device_authorizations, :team_membership_id, :bigint
  end

  def down
    return unless column_exists?(:oauth_device_authorizations, :team_membership_id)

    remove_column :oauth_device_authorizations, :team_membership_id, :bigint
  end
end
