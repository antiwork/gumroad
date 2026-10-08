#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for bin/vitest-ci's choice of test files. Runs from the repository root
# against the real app/javascript tree, so a selection depends on real imports.
#
#   ruby spec/bin/vitest_ci_test.rb

require "open3"

SCRIPT = File.expand_path("../../bin/vitest-ci", __dir__)
Dir.chdir(File.expand_path("../..", __dir__))

$failures = []
$count = 0

# Records are [status, path, ...], sent as `git diff --name-status -z` output.
def plan(*records)
  input = records.map { |record| record.join("\0") + "\0" }.join
  out, status = Open3.capture2("ruby", SCRIPT, "--plan", stdin_data: input)
  raise "bin/vitest-ci --plan failed" unless status.success?
  mode, *rest = out.split("\n")
  [mode, rest]
end

def check(name)
  $count += 1
  ok = yield
  $failures << name unless ok
  puts "#{ok ? 'ok  ' : 'FAIL'} #{name}"
end

FILE_READING_TEST = "app/javascript/components/gap_cursor_styles.test.ts"

mode, tests = plan(["M", "app/javascript/widget/utils.ts"])
check("a changed source file selects the test that imports it") { mode == "tests" && tests.include?("app/javascript/widget/utils.test.ts") }
check("a changed source file does not select unrelated tests") { !tests.include?("app/javascript/data/customer_surcharge.test.ts") }

mode, tests = plan(["M", "app/javascript/utils/currency.ts"])
check("a type-only import counts: currency.ts selects customer_surcharge.test.ts") { mode == "tests" && tests.include?("app/javascript/data/customer_surcharge.test.ts") }

mode, tests = plan(["M", "app/javascript/data/customer_surcharge.test.ts"])
check("a changed test file selects itself") { mode == "tests" && tests.include?("app/javascript/data/customer_surcharge.test.ts") }

mode, tests = plan(["M", "app/javascript/stylesheets/tailwind.css"])
check("tests that read repository files always run") { mode == "tests" && tests.include?(FILE_READING_TEST) }

mode, tests = plan(["M", "app/models/user.rb"])
check("a Ruby-only change runs only the file-reading tests") { mode == "tests" && tests.include?(FILE_READING_TEST) && !tests.include?("app/javascript/widget/utils.test.ts") }

mode, = plan
check("a branch with no changes runs nothing") { mode == "none" }
mode, = plan(["D", "app/models/user.rb"])
check("a deleted Ruby file alone runs nothing") { mode == "none" }

mode, tests = plan(["R100", "app/models/a.rb", "app/models/b.rb"], ["M", "app/javascript/widget/utils.ts"])
check("-z records with a rename parse into the right paths") { mode == "tests" && tests.include?("app/javascript/widget/utils.test.ts") }

[
  "package.json", "package-lock.json", ".npmrc", "patches/@typia+unplugin+12.1.1.patch",
  "vitest.config.ts", "vite.config.ts", "vite.config.widget.ts", "tsconfig.json",
  "scripts/__fixtures__/typia_shared_program/index.ts", "app/javascript/types/global.d.ts",
  "bin/vitest-ci", ".github/workflows/tests.yml",
].each do |path|
  mode, = plan(["M", path])
  check("#{path} runs the whole suite") { mode == "full" }
end

mode, = plan(["D", "app/javascript/utils/old.ts"])
check("a deleted TS file runs the whole suite") { mode == "full" }
mode, = plan(["R090", "app/javascript/a.tsx", "app/javascript/b.tsx"])
check("a renamed TSX file runs the whole suite") { mode == "full" }

puts
if $failures.empty?
  puts "#{$count} checks passed"
else
  puts "#{$failures.size} of #{$count} checks failed"
  exit 1
end
