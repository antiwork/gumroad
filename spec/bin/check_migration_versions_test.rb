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

def version_of(filename)
  filename[/\A\d+/]
end

def build_repo(dir, base_migrations:, head_migrations:, base_schema: nil, head_schema: nil)
  base_schema ||= base_migrations.map { |name| version_of(name) }.max
  head_schema ||= head_migrations.map { |name| version_of(name) }.max

  Dir.chdir(dir) do
    system("git init -q .", exception: true)
    system("git config user.email t@t.t", exception: true)
    system("git config user.name t", exception: true)
    # A developer with global commit signing on would otherwise fail or hang
    # here for reasons having nothing to do with the checker.
    system("git config commit.gpgsign false", exception: true)
    FileUtils.mkdir_p("db/migrate")

    write = lambda do |migrations, schema_version|
      FileUtils.rm_rf("db/migrate")
      FileUtils.mkdir_p("db/migrate")
      migrations.each { |name| File.write("db/migrate/#{name}", "# noop\n") }
      s = schema_version.to_s
      grouped = s.length == 14 ? [s[0, 4], s[4, 2], s[6, 2], s[8, 6]].join("_") : s
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

    # Exact code, not just nonzero: callers gate a required status on 1 meaning
    # "collides" and treat every other nonzero as "could not run", so a finding
    # that exited 2 would silently stop blocking anything.
    expected_status = expect == :pass ? 0 : 1
    actual = status.exitstatus == expected_status ? expect : "exit #{status.exitstatus}"
    if actual != expect
      $failures << "#{name}\n    expected #{expect} (exit #{expected_status}), got #{actual}\n#{combined.gsub(/^/, '    ')}"
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

# Operational failures must be distinguishable from findings, because the push
# guard writes a failing required status on a finding and nothing on anything
# else. Exit 1 here would block every clean PR on a transient git failure.
def check_operational(name, argv:, **repo_args)
  $count += 1
  Dir.mktmpdir do |dir|
    build_repo(dir, **repo_args)
    stdout, stderr, status = Open3.capture3("ruby", CHECKER, *argv, chdir: dir)
    combined = stdout + stderr

    if status.exitstatus != 2
      $failures << "#{name}\n    expected exit 2 (could not run), got #{status.exitstatus}\n#{combined.gsub(/^/, '    ')}"
      puts "  FAIL  #{name}"
      return
    end

    unless combined.include?("could not run")
      $failures << "#{name}\n    output missing \"could not run\"\n#{combined.gsub(/^/, '    ')}"
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

# The suggested literal has to be Rails' YYYY_MM_DD_HHMMSS grouping, or the
# author pastes a number that reads as a different date.
check(
  "schema.rb suggestion uses Rails' date grouping",
  base_migrations: %w[20261206000014_a.rb],
  head_migrations: %w[20261206000014_a.rb 20261206000020_b.rb],
  head_schema: "20261206000014",
  expect: :fail,
  expect_output: "define(version: 2026_12_06_000020)"
)

# Engine-installed migrations carry a dotted infix
# (`..._add_service_name_to_active_storage_blobs.active_storage.rb`). Rails
# parses a version out of them and aborts on the duplicate; a stricter filename
# pattern here would leave four migrations on main invisible to every rule.
check(
  "duplicate against an engine migration's dotted filename",
  base_migrations: %w[20261206000014_a.rb 20261206000020_create_active_storage_tables.active_storage.rb],
  head_migrations: %w[20261206000014_a.rb 20261206000020_create_active_storage_tables.active_storage.rb 20261206000020_mine.rb],
  base_schema: "20261206000020",
  head_schema: "20261206000020",
  expect: :fail,
  expect_output: "Duplicate migration version 20261206000020"
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

# The exit-code contract both shell callers branch on.
check_operational(
  "unresolvable base ref exits operational, not as a collision",
  argv: %w[no-such-ref HEAD],
  base_migrations: %w[20261206000010_a.rb],
  head_migrations: %w[20261206000010_a.rb 20261206000011_b.rb]
)

check_operational(
  "unresolvable head ref exits operational, not as a collision",
  argv: %w[base no-such-ref],
  base_migrations: %w[20261206000010_a.rb],
  head_migrations: %w[20261206000010_a.rb 20261206000011_b.rb]
)

# --- The guard workflow's path filter -------------------------------------
#
# The filter decides whether the checker above runs at all when main moves, so a
# gap there is invisible to every check written so far. It is exercised here by
# extracting the step's real `run:` body out of the workflow YAML -- a
# paraphrase would drift the first time someone edits the workflow.

require "yaml"

WORKFLOW = File.expand_path("../../.github/workflows/migration-version-guard.yml", __dir__)

def guard_filter_body
  steps = YAML.load_file(WORKFLOW).fetch("jobs").fetch("recheck_open_prs").fetch("steps")
  steps.find { |s| s["id"] == "touched" }.fetch("run")
end

# Runs the filter over a main that moved from `before` to `after`, where the
# push wrote exactly `files`. Returns "true"/"false" -- whether open PRs get
# re-checked.
def filter_runs_for(files)
  Dir.mktmpdir do |dir|
    Dir.chdir(dir) do
      system("git init -q -b main .", exception: true)
      system("git config user.email t@t.t", exception: true)
      system("git config user.name t", exception: true)
      system("git config commit.gpgsign false", exception: true)
      FileUtils.mkdir_p("db/migrate")
      File.write("db/migrate/20261206000010_a.rb", "# noop\n")
      File.write("db/schema.rb", "ActiveRecord::Schema[7.1].define(version: 2026_12_06_000010) do\nend\n")
      File.write("README.md", "x\n")
      system("git add -A && git commit -q -m base", exception: true)
      before = `git rev-parse HEAD`.strip

      files.each { |path, contents| FileUtils.mkdir_p(File.dirname(path)); File.write(path, contents) }
      system("git add -A && git commit -q -m push", exception: true)
      after = `git rev-parse HEAD`.strip

      output = File.join(dir, "github_output")
      File.write(output, "")
      env = { "BEFORE" => before, "AFTER" => after, "GITHUB_OUTPUT" => output }
      Open3.capture3(env, "bash", "-c", guard_filter_body, chdir: dir)
      File.read(output)[/changed=(\w+)/, 1]
    end
  end
end

def check_filter(name, files:, expect:)
  $count += 1
  actual = filter_runs_for(files)
  if actual == expect
    puts "  ok    #{name}"
  else
    puts "  FAIL  #{name}"
    $failures << "#{name}: expected changed=#{expect}, got changed=#{actual.inspect}"
  end
end

# A main push that only raises schema.rb buries any open PR migration numbered
# at or below the new line (rule 3), so it has to trigger the re-check even
# though db/migrate did not move.
check_filter(
  "a schema.rb-only push on main re-checks open PRs",
  files: { "db/schema.rb" => "ActiveRecord::Schema[7.1].define(version: 2026_12_06_000099) do\nend\n" },
  expect: "true"
)

check_filter(
  "a db/migrate push on main re-checks open PRs",
  files: { "db/migrate/20261206000011_b.rb" => "# noop\n",
           "db/schema.rb" => "ActiveRecord::Schema[7.1].define(version: 2026_12_06_000011) do\nend\n" },
  expect: "true"
)

# The filter exists to keep every unrelated main push from re-checking every
# open PR; if this ever reads true the guard is just running constantly.
check_filter(
  "a push touching neither path skips the re-check",
  files: { "README.md" => "unrelated\n" },
  expect: "false"
)

# --- ci-green.yml's publisher --------------------------------------------
#
# ci/green is the only status the main ruleset requires, so this step deciding
# to write `success` IS the merge decision. The verdict it reads can be "we did
# not check" (unknown), and publishing green on that grants the required status
# to a head nobody compared against main. Same extraction trick: the real `run:`
# body, not a paraphrase of it.

CI_GREEN_WORKFLOW = File.expand_path("../../.github/workflows/ci-green.yml", __dir__)

def publisher_body
  steps = YAML.load_file(CI_GREEN_WORKFLOW).fetch("jobs").fetch("report").fetch("steps")
  steps.find { |s| s["name"].to_s.start_with?("Set ci/green") }.fetch("run")
end

# Runs the publisher with `gh` stubbed onto PATH, and returns the ci/green write
# it made -- or nil when it deliberately wrote nothing.
def publisher_write_for(conclusion:, collision:)
  Dir.mktmpdir do |dir|
    writes = File.join(dir, "writes.log")
    bin = File.join(dir, "bin")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "gh"), <<~SH)
      #!/usr/bin/env bash
      state=""
      while [ $# -gt 0 ]; do
        [ "$1" = "-f" ] && case "$2" in state=*) state="${2#state=}" ;; esac
        shift
      done
      echo "$state" >> "#{writes}"
    SH
    FileUtils.chmod(0o755, File.join(bin, "gh"))

    env = {
      "PATH" => "#{bin}:#{ENV['PATH']}",
      "GH_TOKEN" => "x",
      "GITHUB_REPOSITORY" => "antiwork/gumroad",
      "SHA" => "0" * 40,
      "CONCLUSION" => conclusion,
      "COLLISION" => collision,
      "RUN_URL" => "https://example.invalid/run"
    }
    Open3.capture3(env, "bash", "-c", publisher_body, chdir: dir)
    written = File.exist?(writes) ? File.read(writes).strip : ""
    written.empty? ? nil : written
  end
end

def check_publisher(name, conclusion:, collision:, expect:)
  $count += 1
  actual = publisher_write_for(conclusion:, collision:)
  if actual == expect
    puts "  ok    #{name}"
  else
    puts "  FAIL  #{name}"
    $failures << "#{name}: expected ci/green=#{expect.inspect}, got #{actual.inspect}"
  end
end

check_publisher(
  "a clean re-check grants ci/green",
  conclusion: "success", collision: "no", expect: "success"
)

check_publisher(
  "a collision fails ci/green",
  conclusion: "success", collision: "yes", expect: "failure"
)

# The one this exists for. `unknown` means the re-check could not run, and a
# green here would be a guess on the status that gates the merge -- it would
# also paper over a failure the push:main guard may already have written on
# this same SHA. Pending blocks the merge and a re-run resolves it.
check_publisher(
  "an unknown migration verdict leaves ci/green unset",
  conclusion: "success", collision: "unknown", expect: nil
)

# Distinct from unknown: there was no rule to apply, so withholding green would
# strand the PR forever rather than stall it until a re-run.
check_publisher(
  "a skipped re-check still grants ci/green",
  conclusion: "success", collision: "skipped", expect: "success"
)

check_publisher(
  "a failed suite fails ci/green regardless of the verdict",
  conclusion: "failure", collision: "no", expect: "failure"
)

check_publisher(
  "a cancelled run leaves ci/green unset",
  conclusion: "cancelled", collision: "no", expect: nil
)

puts
if $failures.empty?
  puts "#{$count} checks passed."
  exit 0
end

warn "#{$failures.size} of #{$count} checks FAILED:\n\n"
$failures.each { |f| warn "  #{f}\n\n" }
exit 1
