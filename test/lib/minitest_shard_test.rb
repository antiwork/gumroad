# frozen_string_literal: true

require "test_helper"

# bin/minitest-shard decides which files each CI shard runs, so a bug in it
# silently drops coverage: a file in no shard is never run, and CI still goes
# green. These assert the two properties the workflow depends on — every file
# lands somewhere, and no file lands twice — plus the failure mode that would be
# worst in practice, an empty shard, which makes `rails test` with no arguments
# run the entire tree instead.
class MinitestShardTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("bin/minitest-shard").to_s

  def shard(index, total)
    output = `#{SCRIPT} #{index} #{total}`
    assert_predicate $?, :success?, "bin/minitest-shard #{index} #{total} failed"
    output.split
  end

  def all_test_files
    Dir.chdir(Rails.root) { Dir["test/**/*_test.rb"].sort }
  end

  test "the shards together cover every test file exactly once" do
    [1, 2, 3, 7].each do |total|
      shards = (0...total).map { shard(_1, total) }
      combined = shards.flatten

      assert_equal all_test_files, combined.sort, "shard set for total=#{total} does not cover the tree"
      assert_equal combined.size, combined.uniq.size, "a file appears in more than one shard for total=#{total}"
    end
  end

  test "no shard comes back empty" do
    # Not just tidiness: `rails test` with no file arguments runs everything, so
    # an empty shard would quietly double the work rather than do none of it.
    # The script exits non-zero in that case, which `shard` asserts against.
    [2, 3, 7].each do |total|
      (0...total).each { |index| assert_not_empty shard(index, total), "shard #{index} of #{total} is empty" }
    end
  end

  # Deliberately not asserted here: how *evenly* the shards are balanced. That's a
  # performance property, and pinning it to a threshold in a unit test would
  # either measure the script against its own weighting (tautological) or fail on
  # an arbitrary line the next added test file happens to cross. Check balance
  # with `bin/minitest-shard --report 2` and against the real job timings in CI.
  test "an out-of-range shard index is refused rather than silently empty" do
    `#{SCRIPT} 2 2 2>/dev/null`
    assert_not_predicate $?, :success?, "index equal to total should be rejected"

    `#{SCRIPT} -1 2 2>/dev/null`
    assert_not_predicate $?, :success?, "negative index should be rejected"
  end
end
