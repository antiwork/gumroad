# frozen_string_literal: true

require "test_helper"

class AnalyticsPolicyTest < ActiveSupport::TestCase
  include PolicyAssertions

  ACTIONS = %i[index?].freeze

  test "grants access to owner" do
    assert_policy_permits AnalyticsPolicy, :analytics, :named_seller, *ACTIONS
  end

  test "grants access to accountant" do
    assert_policy_permits AnalyticsPolicy, :analytics, :accountant_for_named_seller, *ACTIONS
  end

  test "grants access to admin" do
    assert_policy_permits AnalyticsPolicy, :analytics, :admin_for_named_seller, *ACTIONS
  end

  test "grants access to marketing" do
    assert_policy_permits AnalyticsPolicy, :analytics, :marketing_for_named_seller, *ACTIONS
  end

  test "grants access to support" do
    assert_policy_permits AnalyticsPolicy, :analytics, :support_for_named_seller, *ACTIONS
  end
end
