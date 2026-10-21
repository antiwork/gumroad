# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("db/migrate/20261219000001_add_application_id_indexes_to_oauth_credentials").to_s

describe AddApplicationIdIndexesToOauthCredentials do
  subject(:migration) { described_class.new }

  let(:connection) { ActiveRecord::Base.connection }
  let(:tables) { %i[oauth_access_grants oauth_access_tokens] }
  let(:columns) { %w[application_id revoked_at] }

  # DDL is not rolled back with the example, so put back anything the example dropped.
  after do
    tables.each do |table|
      connection.add_index(table, columns, if_not_exists: true)
    end
  end

  def indexed_columns(table)
    connection.indexes(table).map { |index| index.columns.map(&:to_s) }
  end

  def drop_indexes
    tables.each do |table|
      connection.remove_index(table, columns) if indexed_columns(table).include?(columns)
    end
  end

  # schema.rb already carries both indexes, which is the state a rerun meets after a run added an
  # index and then failed before the version was recorded.
  it "leaves indexes that already exist alone" do
    expect { migration.migrate(:up) }.not_to change { tables.map { |table| indexed_columns(table) } }
  end

  it "adds the index a previous run did not reach" do
    connection.remove_index(:oauth_access_tokens, columns)

    migration.migrate(:up)

    expect(indexed_columns(:oauth_access_tokens)).to include(columns)
  end

  it "adds both indexes when neither is present" do
    drop_indexes

    migration.migrate(:up)

    expect(tables.map { |table| indexed_columns(table) }).to all(include(columns))
  end

  it "removes both indexes on the way down" do
    migration.migrate(:down)

    expect(tables.flat_map { |table| indexed_columns(table) }).not_to include(columns)
  end

  # Rollback has to survive the same partial state `up` does: a run that added one index and then
  # failed leaves the other one absent, so an unguarded remove_index would raise there.
  it "removes only the index a partial run left behind on the way down" do
    connection.remove_index(:oauth_access_grants, columns)

    expect { migration.migrate(:down) }.not_to raise_error
    expect(tables.flat_map { |table| indexed_columns(table) }).not_to include(columns)
  end

  it "is a no-op on the way down when neither index is present" do
    drop_indexes

    expect { migration.migrate(:down) }.not_to raise_error
    expect(tables.flat_map { |table| indexed_columns(table) }).not_to include(columns)
  end

  it "can be rolled back twice" do
    migration.migrate(:down)

    expect { migration.migrate(:down) }.not_to raise_error
  end
end
