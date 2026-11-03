# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("db/migrate/20261224000007_add_team_membership_id_to_oauth_access_grants").to_s
require Rails.root.join("db/migrate/20261224000008_add_team_membership_id_to_oauth_device_authorizations").to_s

# The superseded versions are spelled out rather than read from the migrations, so the spec still
# exercises a database that ran them against a migration that does not know about them.
[
  [AddTeamMembershipIdToOauthAccessGrants, :oauth_access_grants, "20261223000007"],
  [AddTeamMembershipIdToOauthDeviceAuthorizations, :oauth_device_authorizations, "20261223000008"],
].each do |migration_class, table, superseded_version|
  describe migration_class do
    subject(:migration) { described_class.new }

    let(:connection) { ActiveRecord::Base.connection }
    let(:table_name) { table }
    let(:superseded) { superseded_version }

    def column? = connection.column_exists?(table_name, :team_membership_id)

    def record_superseded_version
      connection.execute("INSERT INTO schema_migrations (version) VALUES (#{connection.quote(superseded)})")
    end

    # DDL is not rolled back with the example, so put back anything the example dropped.
    after do
      connection.add_column(table_name, :team_membership_id, :bigint, if_not_exists: true)
      connection.execute("DELETE FROM schema_migrations WHERE version = #{connection.quote(superseded)}")
    end

    it "adds the column to a database migrated from main" do
      connection.remove_column(table_name, :team_membership_id)

      migration.migrate(:up)

      expect(column?).to eq(true)
    end

    it "leaves the column of a database that ran the superseded version" do
      record_superseded_version

      expect { migration.migrate(:up) }.not_to raise_error
      migration.migrate(:down)

      expect(column?).to eq(true)
    end

    it "removes the column on rollback where the superseded version never ran" do
      migration.migrate(:down)

      expect(column?).to eq(false)
    end
  end
end
