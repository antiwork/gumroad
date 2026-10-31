# frozen_string_literal: true

class AddIsPartnerToOauthApplications < ActiveRecord::Migration[8.1]
  # This migration first ran as these numbers. main uses them for its own migrations now, so a database
  # with main's migrations records them too, and down keeps the column there, as CONTRIBUTING.md asks
  # for a renumbered migration.
  SUPERSEDED_VERSIONS = %w[20261220000001 20261221000001].freeze

  def up
    add_column :oauth_applications, :is_partner, :boolean, default: false, null: false, if_not_exists: true
  end

  def down
    return if select_value("SELECT 1 FROM schema_migrations WHERE version IN (#{SUPERSEDED_VERSIONS.map { connection.quote(_1) }.join(", ")})").present?

    remove_column :oauth_applications, :is_partner, if_exists: true
  end
end
