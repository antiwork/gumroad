# frozen_string_literal: true

class AddTeamMembershipIdToOauthAccessTokens < ActiveRecord::Migration[7.1]
  # Renumbered from 20261222000001, which main also took. A preview database that ran the old
  # number already has the column.
  SUPERSEDED_VERSION = "20261222000001"

  def up
    return if column_exists?(:oauth_access_tokens, :team_membership_id)

    change_table :oauth_access_tokens, bulk: true do |t|
      t.bigint :team_membership_id
      t.index :team_membership_id
    end
  end

  # Where the old number recorded this column, the column belongs to that row, so a rollback
  # leaves it in place. Main's CreateSellerPlanOffers shares the number, so the row alone does not
  # say which migration ran: only the token migration's row leaves seller_plan_offers missing.
  def down
    return if superseded_version_owns_column?
    return unless column_exists?(:oauth_access_tokens, :team_membership_id)

    remove_column :oauth_access_tokens, :team_membership_id
  end

  private
    def superseded_version_owns_column?
      return false if table_exists?(:seller_plan_offers)

      connection.select_value(
        ActiveRecord::Base.sanitize_sql_array(
          ["SELECT 1 FROM schema_migrations WHERE version = ? LIMIT 1", SUPERSEDED_VERSION]
        )
      ).present?
    end
end
