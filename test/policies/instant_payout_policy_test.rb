# frozen_string_literal: true

require "test_helper"

class InstantPayoutPolicyTest < ActiveSupport::TestCase
  include PolicyAssertions

  ACTIONS = %i[create?].freeze

  test "grants access to owner" do
    assert_policy_permits InstantPayoutPolicy, :instant_payout, :named_seller, *ACTIONS
  end
  test "grants access to accountant" do
    assert_policy_permits InstantPayoutPolicy, :instant_payout, :accountant_for_named_seller, *ACTIONS
  end
  test "grants access to admin" do
    assert_policy_permits InstantPayoutPolicy, :instant_payout, :admin_for_named_seller, *ACTIONS
  end
  test "denies access to marketing" do
    refute_policy_permits InstantPayoutPolicy, :instant_payout, :marketing_for_named_seller, *ACTIONS
  end
  test "denies access to support" do
    refute_policy_permits InstantPayoutPolicy, :instant_payout, :support_for_named_seller, *ACTIONS
  end
end
