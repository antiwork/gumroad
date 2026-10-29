# frozen_string_literal: true

class AddTeamMembershipIdToOauthAccessTokens < ActiveRecord::Migration[7.1]
  # Renumbered from 20261222000001, which main also took. A preview database that ran the old
  # number already has the column.
  def up
    return if column_exists?(:oauth_access_tokens, :team_membership_id)

    change_table :oauth_access_tokens, bulk: true do |t|
      t.bigint :team_membership_id
      t.index :team_membership_id
    end
  end

  def down
    return unless column_exists?(:oauth_access_tokens, :team_membership_id)

    remove_column :oauth_access_tokens, :team_membership_id
  end
end
