# frozen_string_literal: true

require "test_helper"

class DashboardPolicyTest < ActiveSupport::TestCase
  include PolicyAssertions

  ACTIONS = %i[index?].freeze

  test "grants access to owner" do
    assert_policy_permits DashboardPolicy, :dashboard, :named_seller, *ACTIONS
  end

  test "grants access to accountant" do
    assert_policy_permits DashboardPolicy, :dashboard, :accountant_for_named_seller, *ACTIONS
  end

  test "grants access to admin" do
    assert_policy_permits DashboardPolicy, :dashboard, :admin_for_named_seller, *ACTIONS
  end

  test "grants access to marketing" do
    assert_policy_permits DashboardPolicy, :dashboard, :marketing_for_named_seller, *ACTIONS
  end

  test "grants access to support" do
    assert_policy_permits DashboardPolicy, :dashboard, :support_for_named_seller, *ACTIONS
  end
end
