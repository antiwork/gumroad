# frozen_string_literal: true

class AddTeamMembershipIdToOauthAccessGrants < ActiveRecord::Migration[8.1]
  def change
    add_column :oauth_access_grants, :team_membership_id, :bigint
  end
end
