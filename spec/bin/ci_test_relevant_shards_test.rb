#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for bin/ci-test-relevant-shards, which sizes Test Relevant to the
# selected spec files.
#
#   ruby spec/bin/ci_test_relevant_shards_test.rb

require "open3"

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

if $failures.empty?
  puts "#{$count} checks passed"
else
  $failures.each { |f| puts "FAIL: #{f}" }
  abort "#{$failures.size}/#{$count} checks failed"
end
