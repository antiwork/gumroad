# frozen_string_literal: true

require "test_helper"

class AudiencePolicyTest < ActiveSupport::TestCase
  include PolicyAssertions

  ACTIONS = %i[index? export?].freeze

  test "grants access to owner" do
    assert_policy_permits AudiencePolicy, :audience, :named_seller, *ACTIONS
  end
  test "grants access to accountant" do
    assert_policy_permits AudiencePolicy, :audience, :accountant_for_named_seller, *ACTIONS
  end
  test "grants access to admin" do
    assert_policy_permits AudiencePolicy, :audience, :admin_for_named_seller, *ACTIONS
  end
  test "grants access to marketing" do
    assert_policy_permits AudiencePolicy, :audience, :marketing_for_named_seller, *ACTIONS
  end
  test "grants access to support" do
    assert_policy_permits AudiencePolicy, :audience, :support_for_named_seller, *ACTIONS
  end
end
