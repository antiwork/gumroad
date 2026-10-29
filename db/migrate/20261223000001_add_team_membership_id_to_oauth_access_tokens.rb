# frozen_string_literal: true

class AddTeamMembershipIdToOauthAccessTokens < ActiveRecord::Migration[7.1]
  # Renumbered from 20261222000001, which main also took. A preview database that
  # ran the old number already has the column.
  SUPERSEDED_VERSION = "20261222000001"

  def up
    return if column_exists?(:oauth_access_tokens, :team_membership_id)

    change_table :oauth_access_tokens, bulk: true do |t|
      t.bigint :team_membership_id
      t.index :team_membership_id
    end
  end

  # Where the old number is recorded the column belongs to that row, so a
  # rollback leaves it in place.
  def down
    return if superseded_version_applied?
    return unless column_exists?(:oauth_access_tokens, :team_membership_id)

    remove_column :oauth_access_tokens, :team_membership_id
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
