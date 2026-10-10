#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for bin/ci-test-relevant-shards, which sizes Test Relevant to the
# selected spec files, and for the outputs bin/ci-relevant-specs writes from it.
#
#   ruby spec/bin/ci_test_relevant_shards_test.rb

require "fileutils"
require "open3"
require "tmpdir"

SCRIPT = File.expand_path("../../bin/ci-test-relevant-shards", __dir__)

$failures = []
$count = 0

def shards(files, matrix_size = 12)
  out, status = Open3.capture2("bash", SCRIPT, files.to_s, matrix_size.to_s)
  raise "bin/ci-test-relevant-shards #{files} #{matrix_size} failed" unless status.success?
  Integer(out)
end

def check(name, got, expected)
  $count += 1
  ok = got == expected
  $failures << "#{name}: expected #{expected}, got #{got}" unless ok
  puts "#{ok ? 'ok  ' : 'FAIL'} #{name}"
end

check("one spec file uses the minimum of 4 shards", shards(1), 4)
check("16 spec files still fit in 4 shards", shards(16), 4)
check("17 spec files take a fifth shard", shards(17), 5)
check("30 spec files take 8 shards", shards(30), 8)
check("48 spec files fill the matrix", shards(48), 12)
check("more spec files than the matrix holds stay at the matrix size", shards(92), 12)
check("a matrix smaller than the minimum caps the count", shards(1, 3), 3)

# bin/ci-relevant-specs turns the count into the outputs the workflow reads. A
# throwaway repo with no changes selects the one floor spec, so 4 shards.
def selector_outputs(index)
  Dir.mktmpdir do |dir|
    Dir.chdir(dir) do
      FileUtils.mkdir_p("bin")
      %w[ci-relevant-specs branch-specs ci-test-relevant-shards].each do |script|
        FileUtils.cp(File.expand_path("../../bin/#{script}", __dir__), "bin/#{script}")
      end
      system("git init -q -b main . && git config user.email t@example.com && git config user.name t && git config commit.gpgsign false && git add -A && git commit -q -m base", exception: true)
      output = File.join(dir, "github_output")
      env = { "GITHUB_OUTPUT" => output, "CI_NODE_INDEX" => index.to_s, "CI_NODE_TOTAL" => "12" }
      _, status = Open3.capture2e(env, "bash", "bin/ci-relevant-specs", `git rev-parse HEAD`.strip)
      raise "bin/ci-relevant-specs failed for index #{index}" unless status.success?
      File.readlines(output, chomp: true).to_h { |line| line.split("=", 2) }
    end
  end
end

last_needed = selector_outputs(3)
first_extra = selector_outputs(4)
check("the selector writes the shard count for a needed shard", last_needed["shards"], "4")
check("the selector writes the shard count for an extra shard", first_extra["shards"], "4")
check("the last needed shard runs", last_needed["run"], "true")
check("the first extra shard stops", first_extra["run"], "false")

if $failures.empty?
  puts "#{$count} checks passed"
else
  $failures.each { |f| puts "FAIL: #{f}" }
  abort "#{$failures.size}/#{$count} checks failed"
end
