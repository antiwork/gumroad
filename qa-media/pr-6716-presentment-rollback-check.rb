# frozen_string_literal: true

# Proves the later-charge-presentment migrations' `down` no longer destroys schema owned by the
# versions they were renumbered away from. Runs against a real MySQL database, driving Rails' own
# migrator.
#
#   DATABASE_PASSWORD=... ruby qa-media/pr-6716-presentment-rollback-check.rb
#
# The scenario is any preview app or developer database built from #6495 before the renumber: the
# presentment pair applied under 20261206000015 / 20261206000016, so the renumbered 17/18 run
# against a database that already has the table and column. Rolling 17/18 back must leave both in
# place, because the old versions still own them — and the table holds fixings, which are the
# amounts buyers agreed to be charged.

require "active_record"
require "logger"

DB = ENV.fetch("SCRATCH_DB", "gumroad_pr6716_presentment_rollback")
ROOT = File.expand_path("..", __dir__)
MIGRATE_PATH = File.join(ROOT, "db/migrate")
PRESENTMENT_VERSIONS = %w[20261206000017 20261206000018].freeze
OLD_VERSIONS = %w[20261206000015 20261206000016].freeze

def conn = ActiveRecord::Base.connection

def connect(database)
  ActiveRecord::Base.establish_connection(
    adapter: "mysql2",
    host: ENV.fetch("DATABASE_HOST", "127.0.0.1"),
    port: ENV.fetch("DATABASE_PORT", 3306).to_i,
    username: ENV.fetch("DATABASE_USERNAME", "root"),
    password: ENV.fetch("DATABASE_PASSWORD", "password"),
    database:
  )
end

def state
  table = conn.table_exists?(:later_charge_presentments)
  {
    "later_charge_presentments table" => table,
    "  .canonical_price_cents" => (table ? conn.column_exists?(:later_charge_presentments, :canonical_price_cents) : nil),
    "  fixing rows" => (table ? conn.select_value("SELECT COUNT(*) FROM later_charge_presentments") : nil)
  }
end

def report(label)
  puts "\n#{label}"
  state.each { |k, v| puts format("  %-34s %s", k, v.inspect) }
  puts "  #{'schema_migrations 202612060000xx'.ljust(34)} " \
       "#{conn.select_values("SELECT version FROM schema_migrations WHERE version LIKE '202612060000%' ORDER BY version").inspect}"
end

def migrator(direction, versions)
  migrations = ActiveRecord::MigrationContext.new(MIGRATE_PATH).migrations.select { versions.include?(_1.version.to_s) }
  ActiveRecord::Migrator.new(direction, migrations, ActiveRecord::Base.connection.schema_migration,
                             ActiveRecord::Base.connection.internal_metadata)
end

connect(nil)
conn.drop_database(DB) rescue nil
conn.create_database(DB)
connect(DB)
ActiveRecord::Base.logger = Logger.new(IO::NULL)
conn.schema_migration.create_table
conn.internal_metadata.create_table

# The pre-existing schema as a database that applied the presentment pair under the OLD numbers
# holds it — table, canonical_price_cents, and one stored fixing, which is the data at risk.
conn.create_table :later_charge_presentments, force: true do |t|
  t.references :owner, polymorphic: true, null: false, index: false
  t.string :processor, null: false
  t.string :presentment_currency, null: false
  t.bigint :presentment_price_cents, null: false
  t.decimal :signup_currency_units_per_usd, precision: 30, scale: 15, null: false
  t.datetime :effective_from, null: false
  t.timestamps
end
conn.add_column :later_charge_presentments, :canonical_price_cents, :bigint, null: false
conn.execute(<<~SQL)
  INSERT INTO later_charge_presentments
    (owner_type, owner_id, processor, presentment_currency, presentment_price_cents,
     signup_currency_units_per_usd, canonical_price_cents, effective_from, created_at, updated_at)
  VALUES ('Subscription', 1, 'stripe', 'eur', 899, 0.890000000000000, 1000, NOW(), NOW(), NOW())
SQL
OLD_VERSIONS.each { conn.schema_migration.create_version(_1) }
report("BEFORE — database carrying the old 15/16 presentment history")

migrator(:up, PRESENTMENT_VERSIONS).migrate
report("AFTER db:migrate — renumbered 17/18 run against it (both must be no-ops)")

PRESENTMENT_VERSIONS.reverse_each { migrator(:down, [_1]).migrate }
report("AFTER rolling back 18 then 17 — old versions still own the schema, so it must survive")

failures = []
# Each check is independent: a dropped table must not stop the row count from being reported, or a
# regression prints as a crash instead of a verdict.
failures << "later_charge_presentments table dropped" unless conn.table_exists?(:later_charge_presentments)
if conn.table_exists?(:later_charge_presentments)
  failures << "canonical_price_cents dropped" unless conn.column_exists?(:later_charge_presentments, :canonical_price_cents)
  failures << "fixing row lost" unless conn.select_value("SELECT COUNT(*) FROM later_charge_presentments").to_i == 1
end

# The other half: a database with NO old history owns the schema itself, so down must still clean up.
connect(nil)
conn.drop_database("#{DB}_clean") rescue nil
conn.create_database("#{DB}_clean")
connect("#{DB}_clean")
conn.schema_migration.create_table
conn.internal_metadata.create_table
migrator(:up, PRESENTMENT_VERSIONS).migrate
report("CONTROL — no old history: 17/18 create the schema")
PRESENTMENT_VERSIONS.reverse_each { migrator(:down, [_1]).migrate }
report("CONTROL — rollback owns the schema, so it must be removed")
failures << "control: table survived a rollback that owns it" if conn.table_exists?(:later_charge_presentments)

puts "\n#{failures.empty? ? 'PASS — rollback preserves schema owned by the superseded versions, and still removes schema it owns' : "FAIL — #{failures.join('; ')}"}"
exit(failures.empty? ? 0 : 1)
