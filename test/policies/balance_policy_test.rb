# frozen_string_literal: true

require "test_helper"

class BalancePolicyTest < ActiveSupport::TestCase
  include PolicyAssertions

  # Original RSpec `permissions :index?, :export? do … end` block runs every
  # example against BOTH actions; PolicyAssertions replicates that.
  ACTIONS = %i[index? export?].freeze

  test "grants access to owner" do
    assert_policy_permits BalancePolicy, :balance, :named_seller, *ACTIONS
  end

  test "grants access to accountant" do
    assert_policy_permits BalancePolicy, :balance, :accountant_for_named_seller, *ACTIONS
  end

  test "grants access to admin" do
    assert_policy_permits BalancePolicy, :balance, :admin_for_named_seller, *ACTIONS
  end

  test "denies access to marketing" do
    refute_policy_permits BalancePolicy, :balance, :marketing_for_named_seller, *ACTIONS
  end

  test "grants access to support" do
    assert_policy_permits BalancePolicy, :balance, :support_for_named_seller, *ACTIONS
  end
end
