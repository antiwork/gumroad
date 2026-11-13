# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("db/migrate/20261226000005_create_meta_conversions_settings").to_s

describe CreateMetaConversionsSettings do
  subject(:migration) { described_class.new }

  let(:connection) { ActiveRecord::Base.connection }
  # Spelled out rather than read from the migration, so the spec still exercises a database that ran
  # it under its earlier version against a migration that does not know about it.
  let(:superseded_version) { "20261226000003" }

  def table? = connection.table_exists?(:meta_conversions_settings)

  def table_schema
    columns = connection.columns(:meta_conversions_settings).map { [_1.name, _1.sql_type, _1.null, _1.default] }
    indexes = connection.indexes(:meta_conversions_settings).map { [_1.name, _1.columns, _1.unique] }
    [columns, indexes.sort]
  end

  def record_superseded_version
    connection.execute("INSERT INTO schema_migrations (version) VALUES (#{connection.quote(superseded_version)})")
  end

  def saved_tokens = connection.select_values("SELECT access_token FROM meta_conversions_settings")

  # DDL is not rolled back with the example and commits the rows written before it, so undo both here.
  after do
    connection.execute("DELETE FROM schema_migrations WHERE version = #{connection.quote(superseded_version)}")
    described_class.new.migrate(:up) unless table?
    connection.execute("DELETE FROM meta_conversions_settings WHERE access_token = 'token-1'")
  end

  it "creates the table on a database migrated from main" do
    schema = table_schema
    connection.drop_table(:meta_conversions_settings)

    migration.migrate(:up)

    expect(table_schema).to eq(schema)
  end

  it "keeps the table and its rows where the superseded version already created it" do
    record_superseded_version
    connection.execute(<<~SQL)
      INSERT INTO meta_conversions_settings (user_id, access_token, created_at, updated_at)
      VALUES (1, 'token-1', NOW(), NOW())
    SQL
    schema = table_schema

    expect { migration.migrate(:up) }.not_to raise_error
    migration.migrate(:down)

    expect(table_schema).to eq(schema)
    expect(saved_tokens).to eq(["token-1"])
  end

  it "drops the table on rollback where the superseded version is not recorded" do
    expect { migration.migrate(:up) }.not_to raise_error
    migration.migrate(:down)

    expect(table?).to eq(false)
  end
end
