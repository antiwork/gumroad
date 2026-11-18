# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("db/migrate/20261226000008_add_processor_amount_to_disputes").to_s

describe AddProcessorAmountToDisputes do
  subject(:migration) { described_class.new }

  let(:connection) { ActiveRecord::Base.connection }
  # Spelled out rather than read from the migration, so the spec still checks the number the branch's
  # preview database and main's AddTestingAndQaTaxonomy both record.
  let(:superseded_version) { "20261226000007" }
  let!(:superseded_version_was_recorded) { superseded_version_recorded? }

  def superseded_version_recorded?
    connection.select_value("SELECT 1 FROM schema_migrations WHERE version = #{connection.quote(superseded_version)}").present?
  end

  def columns
    %i[processor_amount_cents processor_currency].select { connection.column_exists?(:disputes, _1) }
  end

  # DDL is not rolled back with the example, so put back anything the example dropped.
  after do
    connection.add_column(:disputes, :processor_amount_cents, :bigint, if_not_exists: true)
    connection.add_column(:disputes, :processor_currency, :string, if_not_exists: true)
    if superseded_version_was_recorded && !superseded_version_recorded?
      connection.execute("INSERT INTO schema_migrations (version) VALUES (#{connection.quote(superseded_version)})")
    end
  end

  it "adds both columns to a database without them" do
    connection.remove_column(:disputes, :processor_currency)
    connection.remove_column(:disputes, :processor_amount_cents)

    migration.migrate(:up)

    expect(columns).to eq(%i[processor_amount_cents processor_currency])
    expect(connection.columns(:disputes).find { _1.name == "processor_amount_cents" }.sql_type).to eq("bigint")
  end

  it "runs without error against a database that ran the superseded version and already has both columns" do
    expect { migration.migrate(:up) }.not_to raise_error

    expect(columns).to eq(%i[processor_amount_cents processor_currency])
  end

  it "adds only the missing column when one of them is already there" do
    connection.remove_column(:disputes, :processor_currency)

    migration.migrate(:up)

    expect(columns).to eq(%i[processor_amount_cents processor_currency])
  end

  it "keeps the columns on rollback while the superseded version is recorded, whichever migration recorded it" do
    connection.execute("INSERT INTO schema_migrations (version) VALUES (#{connection.quote(superseded_version)})") unless superseded_version_recorded?

    migration.migrate(:down)

    expect(columns).to eq(%i[processor_amount_cents processor_currency])
  end

  it "removes both columns on rollback where the superseded version was never recorded" do
    connection.execute("DELETE FROM schema_migrations WHERE version = #{connection.quote(superseded_version)}")

    migration.migrate(:down)

    expect(columns).to be_empty
  end

  it "removes the remaining column on rollback when only one of them is there" do
    connection.execute("DELETE FROM schema_migrations WHERE version = #{connection.quote(superseded_version)}")
    connection.remove_column(:disputes, :processor_currency)

    migration.migrate(:down)

    expect(columns).to be_empty
  end
end
