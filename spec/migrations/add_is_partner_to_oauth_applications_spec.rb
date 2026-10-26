# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("db/migrate/20261221000001_add_is_partner_to_oauth_applications").to_s

describe AddIsPartnerToOauthApplications do
  subject(:migration) { described_class.new }

  let(:connection) { ActiveRecord::Base.connection }
  let(:superseded_version) { "20261220000001" }

  # DDL is not rolled back with the example, so put back the column and the version row.
  around do |example|
    superseded_version_was_recorded = superseded_version_recorded?
    example.run
  ensure
    connection.add_column(:oauth_applications, :is_partner, :boolean, default: false, null: false) unless is_partner_column
    superseded_version_was_recorded ? record_superseded_version : forget_superseded_version
    OauthApplication.reset_column_information
  end

  def is_partner_column
    connection.columns(:oauth_applications).find { _1.name == "is_partner" }
  end

  def superseded_version_recorded?
    connection.select_value("SELECT 1 FROM schema_migrations WHERE version = #{connection.quote(superseded_version)}").present?
  end

  def record_superseded_version
    connection.execute("INSERT IGNORE INTO schema_migrations (version) VALUES (#{connection.quote(superseded_version)})")
  end

  def forget_superseded_version
    connection.execute("DELETE FROM schema_migrations WHERE version = #{connection.quote(superseded_version)}")
  end

  it "skips the column that a run under the superseded number already added" do
    expect { migration.migrate(:up) }.not_to raise_error

    expect(is_partner_column).to have_attributes(sql_type: "tinyint(1)", default: false, null: false)
  end

  it "adds the column when it is missing" do
    connection.remove_column(:oauth_applications, :is_partner)

    migration.migrate(:up)

    expect(is_partner_column).to have_attributes(sql_type: "tinyint(1)", default: false, null: false)
  end

  it "keeps the column on the way down while the superseded version is recorded" do
    record_superseded_version

    migration.migrate(:down)

    expect(is_partner_column).to be_present
  end

  it "removes the column on the way down when the superseded version is not recorded" do
    forget_superseded_version

    migration.migrate(:down)

    expect(is_partner_column).to be_nil
  end
end
