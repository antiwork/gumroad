# frozen_string_literal: true

require "test_helper"

class GumroadDomainConstraintTest < ActiveSupport::TestCase
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

  test "matches? returns true for a host in VALID_REQUEST_HOSTS" do
    with_const(:VALID_REQUEST_HOSTS, ["gumroad.com"]) do
      assert_equal true, GumroadDomainConstraint.matches?(Request.new("gumroad.com"))
    end
  end

  test "matches? returns false for a host not in VALID_REQUEST_HOSTS" do
    with_const(:VALID_REQUEST_HOSTS, ["gumroad.com"]) do
      assert_equal false, GumroadDomainConstraint.matches?(Request.new("api.gumroad.com"))
    end
  end
end
