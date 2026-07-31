# frozen_string_literal: true

DIR = ARGV[0] || "db/migrate"
SCHEMA = ARGV[1] || "db/schema.rb"

# Every deployed database (production included) already has 20261206000000..000016 recorded,
# minus 000007 which was never used.
RECORDED = ((0..16).map { |n| format("202612060000%02d", n) }.map(&:to_i)) - [20261206000007]

def disk_versions(dir)
  Dir.children(dir).grep(/\A\d+_/).map { |f| f[/\A\d+/] }
end

# Mirrors ActiveRecord::Schema.define -> assume_migrated_upto_version
# (activerecord 7.1.6, schema_statements.rb:1329-1349): the fresh-CI-database path.
def schema_load(schema_version, all, recorded)
  migrated = recorded.dup
  migrated << schema_version unless migrated.include?(schema_version)
  inserting = (all.map(&:to_i) - migrated).select { |v| v < schema_version }
  dupes = inserting.tally.select { |_, c| c > 1 }
  dupes.any? ? "ABORT -> Duplicate migration #{dupes.keys.min}" : "OK (#{inserting.size} inserted)"
end

# db:migrate on an existing database: Rails keys completion on the version number alone.
def pending(all, recorded)
  (all.map(&:to_i) - recorded).select { |v| v > 20261206000000 }.sort
end

NAMES = {
  20261206000015 => "guardians(15)",
  20261206000016 => "guardian_id(16)",
  20261206000017 => "presentments(17)",
  20261206000018 => "canonical_price(18)",
  20261206000019 => "guardians(19)",
  20261206000020 => "guardian_id(20)",
}

def report(label, all, schema_version)
  dupes = all.tally.select { |_, c| c > 1 }
  runs = pending(all, RECORDED)
  guardian_runs = runs.any? { |v| [20261206000019, 20261206000015].include?(v) }
  presentment_runs = runs.any? { |v| [20261206000017, 20261206000015].include?(v) }
  puts "== #{label}"
  puts "   duplicate filenames: #{dupes.empty? ? 'none' : dupes.inspect}"
  puts "   fresh CI database (db:prepare schema load): #{schema_load(schema_version, all, [])}"
  puts "   existing database, runs: #{runs.map { |v| NAMES[v] || v }.join(', ')}"
  puts "   -> guardians schema created/reconciled: #{guardian_runs}"
  puts "   -> presentments schema created/reconciled: #{presentment_runs}"
  puts
end

all = disk_versions(DIR)
schema_version = File.read(SCHEMA)[/define\(version: ([\d_]+)\)/, 1].delete("_").to_i
report("THIS BRANCH: presentments 17/18, guardians 19/20", all, schema_version)

report("main today: both pairs at 15/16",
       all - %w[20261206000017 20261206000018 20261206000019 20261206000020] +
         %w[20261206000015 20261206000016 20261206000015 20261206000016], 20261206000016)

report("MUTATION: only presentments renumbered (this PR's previous head)",
       all - %w[20261206000019 20261206000020] + %w[20261206000015 20261206000016], 20261206000018)

report("MUTATION: only guardians renumbered",
       all - %w[20261206000017 20261206000018] + %w[20261206000015 20261206000016], 20261206000020)
