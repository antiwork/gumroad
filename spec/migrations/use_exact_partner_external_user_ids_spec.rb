# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("db/migrate/20261221000004_use_exact_partner_external_user_ids").to_s

describe UseExactPartnerExternalUserIds do
  # MySQL commits each ALTER, so a transaction cannot undo these examples. They write their own rows
  # under an application ID no factory uses, and the around block deletes them and restores the columns.
  self.use_transactional_tests = false

  subject(:migration) { described_class.new }

  let(:connection) { ActiveRecord::Base.connection }
  let(:oauth_application_id) { 2_000_000_001 }
  let(:nfd_e_acute) { "é" }

  around do |example|
    example.run
  ensure
    described_class::TABLES.each { connection.execute("DELETE FROM #{_1} WHERE oauth_application_id = #{oauth_application_id}") }
    described_class::TABLES.each do |table|
      next if collation(table) == described_class::EXACT_COLLATION

      connection.change_column(table, :external_user_id, :string, null: false, collation: described_class::EXACT_COLLATION)
    end
    [PartnerSeller, PartnerMigration].each(&:reset_column_information)
  end

  def collation(table)
    connection.select_value(<<~SQL)
      SELECT collation_name FROM information_schema.columns
      WHERE table_schema = DATABASE() AND table_name = #{connection.quote(table.to_s)} AND column_name = 'external_user_id'
    SQL
  end

  def insert_seller(user_id, external_user_id)
    connection.execute(<<~SQL)
      INSERT INTO partner_sellers (oauth_application_id, user_id, external_user_id, created_at, updated_at)
      VALUES (#{oauth_application_id}, #{user_id}, #{connection.quote(external_user_id)}, NOW(), NOW())
    SQL
  end

  def insert_migration(external_user_id)
    connection.execute(<<~SQL)
      INSERT INTO partner_migrations (oauth_application_id, external_user_id, code_digest, public_id, products, status, expires_at, created_at, updated_at)
      VALUES (#{oauth_application_id}, #{connection.quote(external_user_id)}, #{connection.quote(SecureRandom.hex)}, #{connection.quote(Nanoid.generate)}, '[]', 'pending', NOW(), NOW(), NOW())
    SQL
  end

  def rows(table)
    connection.select_rows("SELECT id, HEX(external_user_id) FROM #{table} WHERE oauth_application_id = #{oauth_application_id} ORDER BY id")
  end

  def indexes(table)
    connection.indexes(table).map { [_1.name, _1.columns, _1.unique] }.sort
  end

  it "compares partner user IDs exactly and keeps every existing row and index" do
    migration.migrate(:down)
    expect(described_class::TABLES.map { collation(_1) }).to all(eq(described_class::TABLE_COLLATION))
    ["aB3x", "café", nfd_e_acute, "ext-9 "].each_with_index { insert_seller(2_000_000_001 + _2, _1) }
    ["aB3x", "Ab3X"].each { insert_migration(_1) }
    rows_before = described_class::TABLES.index_with { rows(_1) }
    indexes_before = described_class::TABLES.index_with { indexes(_1) }

    migration.migrate(:up)

    expect(described_class::TABLES.map { collation(_1) }).to all(eq(described_class::EXACT_COLLATION))
    expect(described_class::TABLES.index_with { rows(_1) }).to eq(rows_before)
    expect(described_class::TABLES.index_with { indexes(_1) }).to eq(indexes_before)
    ["Ab3X", "cafe", "é", "ext-9"].each_with_index { insert_seller(2_000_000_101 + _2, _1) }
    expect(connection.select_value("SELECT COUNT(*) FROM partner_sellers WHERE oauth_application_id = #{oauth_application_id} AND external_user_id = 'ext-9'")).to eq(1)
  end

  it "restores the table collation on the way down and keeps every row" do
    ["aB3x", "café"].each_with_index { insert_seller(2_000_000_001 + _2, _1) }
    insert_migration("aB3x")
    rows_before = described_class::TABLES.index_with { rows(_1) }

    migration.migrate(:down)

    expect(described_class::TABLES.map { collation(_1) }).to all(eq(described_class::TABLE_COLLATION))
    expect(described_class::TABLES.index_with { rows(_1) }).to eq(rows_before)
  end

  it "refuses to go down when partner user IDs would collide and changes nothing" do
    ["aB3x", "Ab3X"].each_with_index { insert_seller(2_000_000_001 + _2, _1) }
    rows_before = rows(:partner_sellers)

    expect { migration.migrate(:down) }.to raise_error(ActiveRecord::IrreversibleMigration, /equal under utf8mb4_unicode_ci/)

    expect(described_class::TABLES.map { collation(_1) }).to all(eq(described_class::EXACT_COLLATION))
    expect(rows(:partner_sellers)).to eq(rows_before)
  end
end
