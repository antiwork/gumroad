# frozen_string_literal: true

require_relative "20261222000001_create_seller_plan_offers"

class AddTeamMembershipIdToOauthAccessTokens < ActiveRecord::Migration[7.1]
  # Renumbered from 20261222000001, which main's CreateSellerPlanOffers also took. A preview
  # database that ran the old number already has the column, and Rails treats that row as
  # CreateSellerPlanOffers having run, so it never creates seller_plan_offers there.
  SUPERSEDED_VERSION = "20261222000001"

  def up
    unless column_exists?(:oauth_access_tokens, :team_membership_id)
      change_table :oauth_access_tokens, bulk: true do |t|
        t.bigint :team_membership_id
        t.index :team_membership_id
      end
    end

    run CreateSellerPlanOffers if superseded_version_recorded? && !table_exists?(:seller_plan_offers)
  end

  # After the repair above, the superseded row stands for both migrations, so no rollback can
  # tell which schema it owns.
  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private
    def superseded_version_recorded?
      connection.select_value(
        ActiveRecord::Base.sanitize_sql_array(
          ["SELECT 1 FROM schema_migrations WHERE version = ? LIMIT 1", SUPERSEDED_VERSION]
        )
      ).present?
    end
end
