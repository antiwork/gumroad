# frozen_string_literal: true

# Proves the guardian migrations' `down` no longer destroys schema owned by the versions they were
# renumbered away from. Runs against a real MySQL database, driving Rails' own migrator.
#
#   DATABASE_URL=... ruby qa-media/pr-6716-rollback-check.rb
#
# The scenario is production's actual history: the guardian pair applied under 20261206000015 /
# 20261206000016, so the renumbered 19/20 run against a database that already has the table and
# column. Rolling 19/20 back must leave both in place, because the old versions still own them.

require "active_record"
require "logger"

DB = ENV.fetch("SCRATCH_DB", "gumroad_pr6716_rollback")
ROOT = File.expand_path("..", __dir__)
MIGRATE_PATH = File.join(ROOT, "db/migrate")
GUARDIAN_VERSIONS = %w[20261206000019 20261206000020].freeze
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
  {
    "guardians table" => conn.table_exists?(:guardians),
    "user_compliance_info.guardian_id" => conn.column_exists?(:user_compliance_info, :guardian_id),
    "guardian rows" => (conn.table_exists?(:guardians) ? conn.select_value("SELECT COUNT(*) FROM guardians") : nil)
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

# The pre-existing schema, exactly as a database that applied the guardian pair under the OLD
# version numbers holds it — plus one stored guardian association, which is the data at risk.
conn.create_table :user_compliance_info, force: true
conn.create_table :guardians, force: true
conn.add_column :user_compliance_info, :guardian_id, :bigint
conn.execute("INSERT INTO guardians () VALUES ()")
conn.execute("INSERT INTO user_compliance_info (guardian_id) VALUES (LAST_INSERT_ID())")
OLD_VERSIONS.each { conn.schema_migration.create_version(_1) }
report("BEFORE — database carrying the old 15/16 guardian history")

migrator(:up, GUARDIAN_VERSIONS).migrate
report("AFTER db:migrate — renumbered 19/20 run against it (both must be no-ops)")

GUARDIAN_VERSIONS.reverse_each { migrator(:down, [_1]).migrate }
report("AFTER rolling back 20 then 19 — old versions still own the schema, so it must survive")

failures = []
# Each check is independent: a dropped table must not stop the row counts from being reported, or a
# regression prints as a crash instead of a verdict.
failures << "guardians table dropped" unless conn.table_exists?(:guardians)
failures << "guardian_id column dropped" unless conn.column_exists?(:user_compliance_info, :guardian_id)
guardian_rows = conn.table_exists?(:guardians) ? conn.select_value("SELECT COUNT(*) FROM guardians").to_i : 0
failures << "guardian row lost" unless guardian_rows == 1
associations = if conn.column_exists?(:user_compliance_info, :guardian_id)
  conn.select_value("SELECT COUNT(*) FROM user_compliance_info WHERE guardian_id IS NOT NULL").to_i
else
  0
end
failures << "stored association lost" unless associations == 1

# The other half: a database with NO old history owns the schema itself, so down must still clean up.
connect(nil)
conn.drop_database("#{DB}_clean") rescue nil
conn.create_database("#{DB}_clean")
connect("#{DB}_clean")
conn.schema_migration.create_table
conn.internal_metadata.create_table
conn.create_table :user_compliance_info, force: true
migrator(:up, GUARDIAN_VERSIONS).migrate
report("CONTROL — no old history: 19/20 create the schema")
GUARDIAN_VERSIONS.reverse_each { migrator(:down, [_1]).migrate }
report("CONTROL — rollback owns the schema, so it must be removed")
failures << "control: guardians table survived a rollback that owns it" if conn.table_exists?(:guardians)
failures << "control: guardian_id survived a rollback that owns it" if conn.column_exists?(:user_compliance_info, :guardian_id)

puts "\n#{failures.empty? ? 'PASS — rollback preserves schema owned by the superseded versions, and still removes schema it owns' : "FAIL — #{failures.join('; ')}"}"
exit(failures.empty? ? 0 : 1)
