# frozen_string_literal: true

require "test_helper"

class ProductReviewPolicyTest < ActiveSupport::TestCase
  include PolicyAssertions

  ACTIONS = %i[index?].freeze

  setup do
    Flipper.remove(:reviews_page)
  end

  teardown do
    Flipper.remove(:reviews_page)
  end

  # feature flag inactive — all roles denied
  test "index? denies owner when reviews_page is inactive" do
    refute_policy_permits ProductReviewPolicy, nil, :named_seller, *ACTIONS
  end

  test "index? denies accountant when reviews_page is inactive" do
    refute_policy_permits ProductReviewPolicy, nil, :accountant_for_named_seller, *ACTIONS
  end

  test "index? denies admin when reviews_page is inactive" do
    refute_policy_permits ProductReviewPolicy, nil, :admin_for_named_seller, *ACTIONS
  end

  test "index? denies marketing when reviews_page is inactive" do
    refute_policy_permits ProductReviewPolicy, nil, :marketing_for_named_seller, *ACTIONS
  end

  test "index? denies support when reviews_page is inactive" do
    refute_policy_permits ProductReviewPolicy, nil, :support_for_named_seller, *ACTIONS
  end

  # feature flag active — only owner permitted
  test "index? grants access to owner when reviews_page is active" do
    Feature.activate_user(:reviews_page, users(:named_seller))
    assert_policy_permits ProductReviewPolicy, nil, :named_seller, *ACTIONS
  ensure
    Feature.deactivate_user(:reviews_page, users(:named_seller))
  end

  test "index? denies accountant when reviews_page is active" do
    Feature.activate_user(:reviews_page, users(:named_seller))
    refute_policy_permits ProductReviewPolicy, nil, :accountant_for_named_seller, *ACTIONS
  ensure
    Feature.deactivate_user(:reviews_page, users(:named_seller))
  end

  test "index? denies admin when reviews_page is active" do
    Feature.activate_user(:reviews_page, users(:named_seller))
    refute_policy_permits ProductReviewPolicy, nil, :admin_for_named_seller, *ACTIONS
  ensure
    Feature.deactivate_user(:reviews_page, users(:named_seller))
  end

  test "index? denies marketing when reviews_page is active" do
    Feature.activate_user(:reviews_page, users(:named_seller))
    refute_policy_permits ProductReviewPolicy, nil, :marketing_for_named_seller, *ACTIONS
  ensure
    Feature.deactivate_user(:reviews_page, users(:named_seller))
  end

  test "index? denies support when reviews_page is active" do
    Feature.activate_user(:reviews_page, users(:named_seller))
    refute_policy_permits ProductReviewPolicy, nil, :support_for_named_seller, *ACTIONS
  ensure
    Feature.deactivate_user(:reviews_page, users(:named_seller))
  end
end
