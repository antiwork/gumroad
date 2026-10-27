# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("db/migrate/20261221000006_add_public_id_to_partner_migrations").to_s

describe AddPublicIdToPartnerMigrations do
  # MySQL commits each ALTER, so a transaction cannot undo these examples. They write their own rows
  # under an application ID no factory uses, and the around block deletes them and rebuilds the column
  # unless it is back in its finished shape.
  self.use_transactional_tests = false

  subject(:migration) { described_class.new }

  let(:connection) { ActiveRecord::Base.connection }
  let(:oauth_application_id) { 2_000_000_001 }

  around do |example|
    example.run
  ensure
    connection.execute("DELETE FROM partner_migrations WHERE oauth_application_id = #{oauth_application_id}")
    connection.remove_column(:partner_migrations, :public_id) if connection.column_exists?(:partner_migrations, :public_id) && !finished_column?
    described_class.new.migrate(:up) unless connection.column_exists?(:partner_migrations, :public_id)
    PartnerMigration.reset_column_information
  end

  # The test database is not in strict mode, so an omitted NOT NULL column would be stored as ''. Once the
  # column exists, public_id is always written, as NULL when not given.
  def insert_migration(external_user_id, status:, public_id: nil)
    columns = "oauth_application_id, external_user_id, code_digest, products, results, status, expires_at, created_at, updated_at"
    values = [oauth_application_id, connection.quote(external_user_id), connection.quote(SecureRandom.hex), connection.quote([{ name: "Texture Pack" }].to_json),
              connection.quote({ "0" => { "product_id" => "abc" } }.to_json), connection.quote(status), "NOW()", "'2026-01-02 03:04:05'", "'2026-01-02 03:04:05'"].join(", ")
    if connection.column_exists?(:partner_migrations, :public_id)
      columns += ", public_id"
      values += ", #{connection.quote(public_id)}"
    end
    connection.execute("INSERT INTO partner_migrations (#{columns}) VALUES (#{values})")
  end

  def rows
    connection.select_rows(<<~SQL)
      SELECT id, HEX(external_user_id), code_digest, CAST(products AS CHAR), CAST(results AS CHAR), status, user_id, expires_at, created_at, updated_at
      FROM partner_migrations WHERE oauth_application_id = #{oauth_application_id} ORDER BY id
    SQL
  end

  def public_ids
    connection.select_values("SELECT public_id FROM partner_migrations WHERE oauth_application_id = #{oauth_application_id} ORDER BY id")
  end

  def public_id_column
    connection.select_one(<<~SQL)
      SELECT collation_name AS collation, is_nullable AS nullable, character_maximum_length AS max_length FROM information_schema.columns
      WHERE table_schema = DATABASE() AND table_name = 'partner_migrations' AND column_name = 'public_id'
    SQL
  end

  def indexes
    connection.indexes(:partner_migrations).map { [_1.name, _1.columns, _1.unique] }.sort
  end

  def finished_column?
    public_id_column == { "collation" => "utf8mb4_0900_bin", "nullable" => "NO", "max_length" => 21 } &&
      indexes.include?(["index_partner_migrations_on_public_id", ["public_id"], true])
  end

  # The state a run leaves when it stops after adding the column, before NOT NULL and the index.
  def add_unfinished_column
    connection.remove_column(:partner_migrations, :public_id) if connection.column_exists?(:partner_migrations, :public_id)
    connection.add_column(:partner_migrations, :public_id, :string, limit: 21, collation: "utf8mb4_0900_bin")
  end

  it "gives every existing row its own Nano ID and keeps every other value and index" do
    migration.migrate(:down)
    expect(connection.column_exists?(:partner_migrations, :public_id)).to be(false)
    insert_migration("aB3x", status: "pending")
    insert_migration("Ab3X", status: "claimed")
    insert_migration("ext-9 ", status: "completed")
    rows_before = rows
    indexes_before = indexes

    migration.migrate(:up)

    expect(rows).to eq(rows_before)
    expect(public_ids).to all(match(/\A[A-Za-z0-9_-]{21}\z/))
    expect(public_ids.uniq.size).to eq(3)
    expect(public_id_column).to eq("collation" => "utf8mb4_0900_bin", "nullable" => "NO", "max_length" => 21)
    expect(indexes).to eq((indexes_before + [["index_partner_migrations_on_public_id", ["public_id"], true]]).sort)
    expect { insert_migration("ext-10", status: "pending", public_id: public_ids.first) }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { insert_migration("ext-11", status: "pending") }.to raise_error(ActiveRecord::NotNullViolation)
  end

  it "keeps public IDs that differ only in case or a trailing space apart" do
    ["aB3xaB3xaB3xaB3xaB3x", "Ab3XAb3XAb3XAb3XAb3X", "aB3xaB3xaB3xaB3xaB3x "].each_with_index do |public_id, index|
      insert_migration("ext-#{index}", status: "pending", public_id:)
    end

    expect(connection.select_value("SELECT COUNT(*) FROM partner_migrations WHERE public_id = 'aB3xaB3xaB3xaB3xaB3x'")).to eq(1)
  end

  it "removes the column on the way down and keeps every row" do
    insert_migration("ext-1", status: "completed", public_id: Nanoid.generate)
    rows_before = rows

    migration.migrate(:down)

    expect(connection.column_exists?(:partner_migrations, :public_id)).to be(false)
    expect(rows).to eq(rows_before)
  end

  it "continues a run that stopped after assigning some IDs, and keeps them" do
    add_unfinished_column
    insert_migration("ext-1", status: "claimed", public_id: "aB3xaB3xaB3xaB3xaB3x_")
    insert_migration("ext-2", status: "pending")
    insert_migration("ext-3", status: "pending")
    rows_before = rows

    migration.migrate(:up)

    expect(rows).to eq(rows_before)
    expect(public_ids.first).to eq("aB3xaB3xaB3xaB3xaB3x_")
    expect(public_ids).to all(match(/\A[A-Za-z0-9_-]{21}\z/))
    expect(public_ids.uniq.size).to eq(3)
    expect(finished_column?).to be(true)
  end

  it "changes nothing when it runs again after finishing" do
    insert_migration("ext-1", status: "claimed", public_id: Nanoid.generate)
    insert_migration("ext-2", status: "pending", public_id: Nanoid.generate)
    state_before = [public_ids, rows, indexes, public_id_column]

    migration.migrate(:up)

    expect([public_ids, rows, indexes, public_id_column]).to eq(state_before)
  end

  it "refuses a column, index, or IDs that it cannot finish from, and assigns nothing" do
    differences = {
      "another collation" => -> { connection.change_column(:partner_migrations, :public_id, :string, limit: 21, collation: "utf8mb4_unicode_ci") },
      "another length" => -> { connection.change_column(:partner_migrations, :public_id, :string, limit: 32, collation: "utf8mb4_0900_bin") },
      "an index that is not unique" => -> { connection.add_index(:partner_migrations, :public_id, name: "index_partner_migrations_on_public_id") },
      "an ID that is not a Nano ID" => -> { insert_migration("ext-2", status: "pending", public_id: "short") },
      "an empty ID" => -> { insert_migration("ext-2", status: "pending", public_id: "") },
      "a duplicate ID" => -> { 2.times { insert_migration("ext-2-#{_1}", status: "pending", public_id: "aB3xaB3xaB3xaB3xaB3x_") } },
    }

    differences.each do |difference, prepare|
      add_unfinished_column
      insert_migration("ext-1", status: "pending")
      prepare.call
      state_before = [public_id_column, indexes]

      expect { migration.migrate(:up) }.to raise_error(RuntimeError, /public_id/), "accepted #{difference}"

      expect(public_ids.first).to be_nil
      expect([public_id_column, indexes]).to eq(state_before)
      connection.execute("DELETE FROM partner_migrations WHERE oauth_application_id = #{oauth_application_id}")
    end
  end
end
