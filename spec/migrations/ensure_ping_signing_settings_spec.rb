# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("db/migrate/20261225000004_ensure_ping_signing_settings").to_s

describe EnsurePingSigningSettings do
  subject(:migration) { described_class.new }

  let(:connection) { ActiveRecord::Base.connection }
  # Spelled out rather than read from the migration, so the spec still exercises a database that ran
  # it against a migration that does not know about it.
  let(:superseded_version) { "20261225000003" }

  def table? = connection.table_exists?(:ping_signing_settings)

  def table_schema
    columns = connection.columns(:ping_signing_settings).map { [_1.name, _1.sql_type, _1.null, _1.default] }
    indexes = connection.indexes(:ping_signing_settings).map { [_1.name, _1.columns, _1.unique] }
    [columns, indexes.sort]
  end

  def superseded_version_recorded?
    connection.select_value("SELECT 1 FROM schema_migrations WHERE version = #{connection.quote(superseded_version)}").present?
  end

  def record_superseded_version
    connection.execute("INSERT INTO schema_migrations (version) VALUES (#{connection.quote(superseded_version)})")
  end

  # DDL is not rolled back with the example, so put back anything the example dropped.
  after do
    connection.execute("DELETE FROM schema_migrations WHERE version = #{connection.quote(superseded_version)}")
    described_class.new.migrate(:up) unless table?
  end

  it "creates the table on a database migrated from main" do
    schema = table_schema
    connection.drop_table(:ping_signing_settings)

    migration.migrate(:up)

    expect(table_schema).to eq(schema)
  end

  # The users-column migration first published as 20261225000003 recorded that version but never
  # created this table.
  it "creates the table where the superseded users-column migration took its version, and keeps it on rollback" do
    schema = table_schema
    connection.drop_table(:ping_signing_settings)
    record_superseded_version

    migration.migrate(:up)
    expect(table_schema).to eq(schema)

    migration.migrate(:down)
    expect(table_schema).to eq(schema)
  end

  it "keeps the table and its rows where the superseded version already created it" do
    record_superseded_version
    setting = create(:user).create_ping_signing_setting!(secret: "s3cret")
    schema = table_schema

    expect { migration.migrate(:up) }.not_to raise_error
    migration.migrate(:down)

    expect(table_schema).to eq(schema)
    expect(setting.reload.secret).to eq("s3cret")
  end

  # schema.rb no longer has a 20261225000003 migration to record, which is the state a database
  # loaded from it is in.
  it "leaves a database loaded from schema.rb unchanged on up and drops the table on rollback" do
    expect(superseded_version_recorded?).to eq(false)
    schema = table_schema

    migration.migrate(:up)
    expect(table_schema).to eq(schema)

    migration.migrate(:down)
    expect(table?).to eq(false)
  end
end
