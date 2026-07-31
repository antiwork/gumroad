#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for bin/check-migration-versions.
#
# Deliberately not an rspec spec: the suite boots Rails and needs a database, and
# `rake db:prepare` aborting on a duplicate version is the exact failure this
# guard exists to catch. A test that cannot run when the bug is present is not a
# test. This builds throwaway git repositories instead -- no Rails, no MySQL.
#
#   ruby spec/bin/check_migration_versions_test.rb

require "tmpdir"
require "fileutils"
require "open3"

CHECKER = File.expand_path("../../bin/check-migration-versions", __dir__)

$failures = []
$count = 0

def build_repo(dir, base_migrations:, head_migrations:, base_schema: nil, head_schema: nil)
  base_schema ||= base_migrations.max
  head_schema ||= head_migrations.max

  Dir.chdir(dir) do
    system("git init -q .", exception: true)
    system("git config user.email t@t.t", exception: true)
    system("git config user.name t", exception: true)
    FileUtils.mkdir_p("db/migrate")

    write = lambda do |migrations, schema_version|
      FileUtils.rm_rf("db/migrate")
      FileUtils.mkdir_p("db/migrate")
      migrations.each { |name| File.write("db/migrate/#{name}", "# noop\n") }
      grouped = schema_version.to_s.scan(/\d{4}|\d{2}/).join("_")
      File.write("db/schema.rb", "ActiveRecord::Schema[7.1].define(version: #{grouped}) do\nend\n")
      system("git add -A", exception: true)
      system("git commit -q -m x --allow-empty", exception: true)
    end

    write.call(base_migrations, base_schema)
    system("git branch -f base HEAD", exception: true)
    write.call(head_migrations, head_schema)
  end
end

def check(name, expect:, expect_output: nil, **repo_args)
  $count += 1
  Dir.mktmpdir do |dir|
    build_repo(dir, **repo_args)
    stdout, stderr, status = Open3.capture3("ruby", CHECKER, "base", "HEAD", chdir: dir)
    combined = stdout + stderr

    actual = status.exitstatus.zero? ? :pass : :fail
    if actual != expect
      $failures << "#{name}\n    expected #{expect}, got #{actual}\n#{combined.gsub(/^/, '    ')}"
      puts "  FAIL  #{name}"
      return
    end

    if expect_output && !combined.include?(expect_output)
      $failures << "#{name}\n    output missing #{expect_output.inspect}\n#{combined.gsub(/^/, '    ')}"
      puts "  FAIL  #{name}"
      return
    end

    puts "  ok    #{name}"
  end
end

puts "check-migration-versions"

# The real incident: #6656 and #6495 each numbered a pair 15/16.
check(
  "duplicate version within the branch (PR #6716)",
  base_migrations: %w[20261206000014_a.rb],
  head_migrations: %w[20261206000014_a.rb 20261206000015_create_guardians.rb 20261206000015_create_later_charge_presentments.rb],
  head_schema: "20261206000015",
  expect: :fail,
  expect_output: "Duplicate migration version 20261206000015"
)

# The cross-PR half: the branch is internally fine, but main spent that version
# on something else while the PR was open.
check(
  "version already used on the base branch by a different migration",
  base_migrations: %w[20261206000014_a.rb 20261206000015_create_guardians.rb],
  head_migrations: %w[20261206000014_a.rb 20261206000015_create_later_charge_presentments.rb],
  expect: :fail,
  expect_output: "already used on base by a different migration"
)

# Would silently never run on a fresh database, which loads schema.rb and marks
# everything at or below that line as applied.
check(
  "new migration numbered at or below the base schema version",
  base_migrations: %w[20261206000010_a.rb 20261206000020_b.rb],
  head_migrations: %w[20261206000010_a.rb 20261206000015_sneaky.rb 20261206000020_b.rb],
  expect: :fail,
  expect_output: "never run there"
)

check(
  "schema.rb left behind the newest migration",
  base_migrations: %w[20261206000014_a.rb],
  head_migrations: %w[20261206000014_a.rb 20261206000020_b.rb],
  head_schema: "20261206000014",
  expect: :fail,
  expect_output: "db/schema.rb is at version 20261206000014"
)

# Must not fire on the ordinary case, or it teaches people to ignore it.
check(
  "clean branch adding a migration above the base's newest",
  base_migrations: %w[20261206000014_a.rb],
  head_migrations: %w[20261206000014_a.rb 20261206000015_b.rb],
  expect: :pass,
  expect_output: "Migration versions OK"
)

check(
  "branch that adds no migrations",
  base_migrations: %w[20261206000014_a.rb],
  head_migrations: %w[20261206000014_a.rb],
  expect: :pass
)

# The base's own migrations arrive unchanged on every branch; flagging them would
# make the check fire on every PR in the repo.
check(
  "unchanged base migrations are not treated as collisions",
  base_migrations: %w[20261206000014_a.rb 20261206000015_b.rb 20261206000016_c.rb],
  head_migrations: %w[20261206000014_a.rb 20261206000015_b.rb 20261206000016_c.rb 20261206000017_d.rb],
  expect: :pass
)

# A version numbered above schema.rb is a normal pending migration, not a bury.
check(
  "pending migration above the base schema version is fine",
  base_migrations: %w[20261206000010_a.rb],
  head_migrations: %w[20261206000010_a.rb 20261206000011_b.rb 20261206000012_c.rb],
  expect: :pass
)

puts
if $failures.empty?
  puts "#{$count} checks passed."
  exit 0
end

warn "#{$failures.size} of #{$count} checks FAILED:\n\n"
$failures.each { |f| warn "  #{f}\n\n" }
exit 1
