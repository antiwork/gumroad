# frozen_string_literal: true

require "test_helper"

class DiscoverDomainConstraintTest < ActiveSupport::TestCase
  Request = Struct.new(:host)

  def with_const(name, value)
    old = Object.const_get(name)
    Object.send(:remove_const, name)
    Object.const_set(name, value)
    yield
  ensure
    Object.send(:remove_const, name)
    Object.const_set(name, old)
  end

  test "matches? returns true for the configured discover host" do
    with_const(:VALID_DISCOVER_REQUEST_HOST, "discover.gumroad.com") do
      assert_equal true, DiscoverDomainConstraint.matches?(Request.new("discover.gumroad.com"))
    end
  end

  test "matches? returns false for a non-discover host" do
    with_const(:VALID_DISCOVER_REQUEST_HOST, "discover.gumroad.com") do
      assert_equal false, DiscoverDomainConstraint.matches?(Request.new("gumroad.com"))
    end
  end
end
