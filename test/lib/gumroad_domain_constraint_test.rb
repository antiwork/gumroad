# frozen_string_literal: true

require "test_helper"

class GumroadDomainConstraintTest < ActiveSupport::TestCase
  Request = Struct.new(:host)

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
