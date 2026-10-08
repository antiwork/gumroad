#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for bin/vitest-ci's choice between related tests and the whole suite.
#
#   ruby spec/bin/vitest_ci_test.rb

require "open3"

SCRIPT = File.expand_path("../../bin/vitest-ci", __dir__)

$failures = []
$count = 0

def plan(*lines)
  out, status = Open3.capture2("ruby", SCRIPT, "--plan", stdin_data: lines.map { |line| "#{line}\n" }.join)
  raise "bin/vitest-ci --plan failed" unless status.success?
  mode, *rest = out.split("\n")
  [mode, rest]
end

def check(name, expected_mode, lines, expected_files = nil)
  $count += 1
  mode, rest = plan(*lines)
  ok = mode == expected_mode && (expected_files.nil? || rest == expected_files)
  $failures << "#{name}: got #{mode} #{rest.inspect}" unless ok
  puts "#{ok ? 'ok  ' : 'FAIL'} #{name}"
end

check "a changed source file runs its related tests", "related",
      ["M\tapp/javascript/widget/utils.ts"], ["app/javascript/widget/utils.ts"]
check "files of any kind pass through to vitest, which ignores what it cannot reach", "related",
      ["M\tapp/javascript/a.tsx", "A\tapp/javascript/a.test.tsx", "M\tapp/models/user.rb"],
      ["app/javascript/a.tsx", "app/javascript/a.test.tsx", "app/models/user.rb"]
check "a branch with no changes runs nothing", "none", []
check "a deleted Ruby file alone runs nothing", "none", ["D\tapp/models/user.rb"]
check "a renamed Ruby file passes its new path", "related",
      ["R100\tapp/models/a.rb\tapp/models/b.rb"], ["app/models/b.rb"]

[
  "package.json", "package-lock.json", ".npmrc", "patches/@typia+unplugin+12.1.1.patch",
  "vitest.config.ts", "vite.config.ts", "vite.config.widget.ts", "tsconfig.json",
  "scripts/__fixtures__/typia_shared_program/index.ts", "bin/vitest-ci", ".github/workflows/tests.yml",
].each do |path|
  check "#{path} runs the whole suite", "full", ["M\t#{path}"]
end

check "a deleted TS file runs the whole suite", "full", ["D\tapp/javascript/utils/old.ts"]
check "a renamed TSX file runs the whole suite", "full", ["R090\tapp/javascript/a.tsx\tapp/javascript/b.tsx"]
check "a deleted JS test file runs the whole suite", "full", ["D\tapp/javascript/x.test.js"]

puts
if $failures.empty?
  puts "#{$count} checks passed"
else
  puts $failures
  puts "#{$failures.size} of #{$count} checks failed"
  exit 1
end
