# frozen_string_literal: true

class AddIsPartnerToOauthApplications < ActiveRecord::Migration[8.1]
  # Renumbered after main took the superseded version, so up skips a column an older run added and
  # down cannot tell who added it: down keeps the column whenever that version is recorded, which is
  # every database on main, leaving schema in place instead of losing data.
  SUPERSEDED_VERSION = "20261220000001"

  def up
    return if column_exists?(:oauth_applications, :is_partner)

    add_column :oauth_applications, :is_partner, :boolean, default: false, null: false
  end

  def down
    return unless column_exists?(:oauth_applications, :is_partner)
    return if superseded_version_applied?

    remove_column :oauth_applications, :is_partner
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
