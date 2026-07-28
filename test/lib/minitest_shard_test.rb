# frozen_string_literal: true

require "test_helper"

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
      combined = (0...total).flat_map { shard(_1, total) }

      assert_equal all_test_files, combined.sort, "shard set for total=#{total} does not cover the tree"
      assert_equal combined.size, combined.uniq.size, "a file appears in more than one shard for total=#{total}"
    end
  end

  test "no shard comes back empty, since a bare rails test would run the whole tree" do
    [2, 3, 7].each do |total|
      (0...total).each { |index| assert_not_empty shard(index, total), "shard #{index} of #{total} is empty" }
    end
  end

  test "an out-of-range shard index is refused rather than silently empty" do
    `#{SCRIPT} 2 2 2>/dev/null`
    assert_not_predicate $?, :success?, "index equal to total should be rejected"

    `#{SCRIPT} -1 2 2>/dev/null`
    assert_not_predicate $?, :success?, "negative index should be rejected"
  end
end
