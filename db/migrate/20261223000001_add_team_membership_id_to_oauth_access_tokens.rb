# frozen_string_literal: true

class AddTeamMembershipIdToOauthAccessTokens < ActiveRecord::Migration[7.1]
  def change
    change_table :oauth_access_tokens, bulk: true do |t|
      t.bigint :team_membership_id
      t.index :team_membership_id
    end
  end
end
