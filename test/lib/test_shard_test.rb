# frozen_string_literal: true

require "test_helper"

class TestShardTest < ActiveSupport::TestCase
  def runnable(*method_names)
    klass = Class.new(Minitest::Test) { method_names.each { |method_name| define_method(method_name) { } } }
    Minitest::Runnable.runnables.delete(klass)
    klass
  end

  test "parses <index>/<total>" do
    assert_equal [0, 6], TestShard.parse("0/6")
    assert_equal [5, 6], TestShard.parse("5/6")
  end

  test "refuses a malformed or out-of-range shard instead of running a wrong slice" do
    ["", "6", "6/6", "7/6", "-1/6", "a/6", "1/0", "1/6 "].each do |value|
      assert_raises(ArgumentError, "#{value.inspect} was accepted") { TestShard.parse(value) }
    end
  end

  test "the shards together run every test exactly once" do
    method_names = (1..500).map { |n| :"test_#{n}" }
    klass = runnable(*method_names)

    [1, 2, 6, 7].each do |total|
      selected = (0...total).flat_map { |index| TestShard.stub(:current, [index, total]) { klass.runnable_methods } }

      assert_equal method_names.map(&:to_s).sort, selected.sort, "shards of #{total} do not cover every test exactly once"
    end
  end

  test "every shard of six gets a fair share of the tests" do
    klass = runnable(*(1..3000).map { |n| :"test_#{n}" })

    6.times do |index|
      count = TestShard.stub(:current, [index, 6]) { klass.runnable_methods.size }
      assert_includes 400..600, count, "shard #{index} of 6 got #{count} of 3000 tests"
    end
  end

  test "runs every test when no shard is set" do
    klass = runnable(:test_a, :test_b)

    TestShard.stub(:current, nil) { assert_equal %w[test_a test_b], klass.runnable_methods.sort }
  end
end
