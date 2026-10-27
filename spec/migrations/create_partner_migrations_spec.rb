# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("db/migrate/20261221000003_create_partner_migrations").to_s

describe CreatePartnerMigrations do
  # MySQL commits each DDL statement, so a transaction cannot undo these examples. The around block moves
  # the real table aside, so each example builds its own partner_migrations, and then puts the real one back.
  self.use_transactional_tests = false

  subject(:migration) { described_class.new }

  let(:connection) { ActiveRecord::Base.connection }
  let(:superseded_version) { "20261220000003" }
  let(:set_aside) { "partner_migrations_spec_original" }

  around do |example|
    superseded_version_was_recorded = superseded_version_recorded?
    connection.execute("RENAME TABLE partner_migrations TO #{set_aside}")
    example.run
  ensure
    connection.execute("DROP TABLE IF EXISTS partner_migrations")
    connection.execute("RENAME TABLE #{set_aside} TO partner_migrations")
    superseded_version_was_recorded ? record_superseded_version : forget_superseded_version
    PartnerMigration.reset_column_information
  end

  # The table exactly as 20261220000003 created it.
  def create_superseded_table
    connection.create_table :partner_migrations do |t|
      t.integer :oauth_application_id, null: false
      t.string :external_user_id, null: false
      t.string :code_digest, null: false
      t.json :products, null: false
      t.json :results
      t.string :status, null: false, default: "pending"
      t.bigint :user_id
      t.datetime :expires_at, null: false
      t.datetime :claimed_at
      t.datetime :completed_at
      t.string :failure_reason
      t.timestamps

      t.index :code_digest, unique: true
      t.index [:oauth_application_id, :external_user_id], name: "index_partner_migrations_on_application_and_external_user"
      t.index :user_id
    end
  end

  def insert_row(external_user_id, **extra)
    values = {
      oauth_application_id: 2_000_000_001, external_user_id:, code_digest: SecureRandom.hex, products: [{ name: "Texture Pack" }].to_json,
      results: { "0" => { "product_id" => "abc" } }.to_json, status: "claimed", user_id: 42, expires_at: "2026-01-09 03:04:05",
      claimed_at: "2026-01-03 03:04:05", created_at: "2026-01-02 03:04:05", updated_at: "2026-01-03 03:04:05", **extra
    }
    connection.execute("INSERT INTO partner_migrations (#{values.keys.join(", ")}) VALUES (#{values.values.map { connection.quote(_1) }.join(", ")})")
  end

  def table_definition
    connection.select_rows("SHOW CREATE TABLE partner_migrations").first.last.sub(/ AUTO_INCREMENT=\d+/, "")
  end

  def rows
    connection.select_rows("SELECT * FROM partner_migrations ORDER BY id")
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

  it "creates the table that the superseded version created, and keeps it on a second run" do
    create_superseded_table
    superseded_definition = table_definition
    connection.drop_table(:partner_migrations)

    migration.migrate(:up)

    expect(table_definition).to eq(superseded_definition)
    expect { migration.migrate(:up) }.not_to change { table_definition }
  end

  it "keeps a populated table that the superseded version created, with its rows and indexes" do
    create_superseded_table
    insert_row("aB3x")
    insert_row("ext-9 ", status: "failed", failure_reason: "The file link expired.")
    record_superseded_version
    definition_before = table_definition
    rows_before = rows

    migration.migrate(:up)

    expect(table_definition).to eq(definition_before)
    expect(rows).to eq(rows_before)
  end

  it "keeps a table that the later partner migrations already changed" do
    connection.execute("CREATE TABLE partner_migrations LIKE #{set_aside}")
    insert_row("aB3x", public_id: "aB3xaB3xaB3xaB3xaB3x_", notified_at: "2026-01-04 03:04:05")
    definition_before = table_definition
    rows_before = rows

    migration.migrate(:up)

    expect(table_definition).to eq(definition_before)
    expect(rows).to eq(rows_before)
  end

  it "refuses a table of another shape and changes nothing" do
    changes = {
      "a missing column" => "ALTER TABLE partner_migrations DROP COLUMN results",
      "another type" => "ALTER TABLE partner_migrations MODIFY products TEXT NOT NULL",
      "a nullable required column" => "ALTER TABLE partner_migrations MODIFY code_digest VARCHAR(255) NULL",
      "another default" => "ALTER TABLE partner_migrations ALTER status SET DEFAULT 'claimed'",
      "another collation" => "ALTER TABLE partner_migrations MODIFY external_user_id VARCHAR(255) COLLATE utf8mb4_bin NOT NULL",
      "an unknown column" => "ALTER TABLE partner_migrations ADD COLUMN secret VARCHAR(255)",
      "a code index that is not unique" => "ALTER TABLE partner_migrations DROP INDEX index_partner_migrations_on_code_digest, ADD INDEX index_partner_migrations_on_code_digest (code_digest)",
      "a missing index" => "ALTER TABLE partner_migrations DROP INDEX index_partner_migrations_on_user_id",
    }

    changes.each do |difference, sql|
      create_superseded_table
      insert_row("aB3x")
      connection.execute(sql)
      definition_before = table_definition
      rows_before = rows

      expect { migration.migrate(:up) }.to raise_error(RuntimeError, /partner_migrations exists in a shape/), "accepted #{difference}"

      expect(table_definition).to eq(definition_before)
      expect(rows).to eq(rows_before)
      connection.drop_table(:partner_migrations)
    end
  end

  it "refuses an unrelated table with the same name" do
    connection.execute("CREATE TABLE partner_migrations (id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255))")
    connection.execute("INSERT INTO partner_migrations (name) VALUES ('unrelated')")

    expect { migration.migrate(:up) }.to raise_error(RuntimeError, /code_digest is missing/)

    expect(rows).to eq([[1, "unrelated"]])
  end

  it "refuses to drop a table that has rows, and keeps them" do
    forget_superseded_version
    create_superseded_table
    insert_row("aB3x")
    rows_before = rows

    expect { migration.migrate(:down) }.to raise_error(ActiveRecord::IrreversibleMigration, /partner_migrations has rows/)

    expect(rows).to eq(rows_before)
  end

  it "keeps an empty table on the way down while the superseded version is recorded" do
    record_superseded_version
    create_superseded_table

    migration.migrate(:down)

    expect(connection.table_exists?(:partner_migrations)).to be(true)
  end

  it "drops an empty table on the way down when the superseded version is not recorded" do
    forget_superseded_version
    migration.migrate(:up)

    migration.migrate(:down)

    expect(connection.table_exists?(:partner_migrations)).to be(false)
  end
end
