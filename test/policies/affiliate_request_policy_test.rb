# frozen_string_literal: true

require "test_helper"

class AffiliateRequestPolicyTest < ActiveSupport::TestCase
  include PolicyAssertions

  ACTIONS = %i[update? approve_all?].freeze

  test "grants access to owner" do
    assert_policy_permits AffiliateRequestPolicy, AffiliateRequest, :named_seller, *ACTIONS
  end
  test "grants access to admin" do
    assert_policy_permits AffiliateRequestPolicy, AffiliateRequest, :admin_for_named_seller, *ACTIONS
  end
  test "grants access to marketing" do
    assert_policy_permits AffiliateRequestPolicy, AffiliateRequest, :marketing_for_named_seller, *ACTIONS
  end
  test "denies access to support" do
    refute_policy_permits AffiliateRequestPolicy, AffiliateRequest, :support_for_named_seller, *ACTIONS
  end
end
