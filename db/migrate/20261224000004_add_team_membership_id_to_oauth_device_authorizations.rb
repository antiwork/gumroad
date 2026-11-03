# frozen_string_literal: true

class AddTeamMembershipIdToOauthDeviceAuthorizations < ActiveRecord::Migration[8.1]
  def change
    add_column :oauth_device_authorizations, :team_membership_id, :bigint
  end
end
