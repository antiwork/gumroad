# frozen_string_literal: true

require "test_helper"

class ApplicationPolicyTest < ActiveSupport::TestCase
  # .allow_anonymous_user_access!
  test "allow_anonymous_user_access! does not affect other policy classes" do
    policy_class_1 = Class.new(ApplicationPolicy)
    policy_class_2 = Class.new(ApplicationPolicy)

    policy_class_1.allow_anonymous_user_access!

    assert_equal true, policy_class_1.allow_anonymous_user_access
    assert_equal false, policy_class_2.allow_anonymous_user_access
    assert_equal false, ApplicationPolicy.allow_anonymous_user_access
  end

  # #initialize
  test "#initialize assigns accessors" do
    user = users(:basic_user)
    seller = users(:named_seller)
    context = SellerContext.new(user:, seller:)
    policy = ApplicationPolicy.new(context, :record)

    assert_equal user, policy.user
    assert_equal seller, policy.seller
    assert_equal :record, policy.record
  end

  test "#initialize raises when user is nil and anonymous access is not allowed" do
    seller = users(:named_seller)
    context = SellerContext.new(user: nil, seller:)
    error = assert_raises(Pundit::NotAuthorizedError) do
      ApplicationPolicy.new(context, :record)
    end
    assert_equal "must be logged in", error.message
  end

  test "#initialize does not raise when user is present and anonymous access is not allowed" do
    user = users(:basic_user)
    seller = users(:named_seller)
    context = SellerContext.new(user:, seller:)
    assert_nothing_raised do
      ApplicationPolicy.new(context, :record)
    end
  end

  test "#initialize does not raise when user is nil and anonymous access is allowed" do
    seller = users(:named_seller)
    policy_class = Class.new(ApplicationPolicy) { allow_anonymous_user_access! }
    context = SellerContext.new(user: nil, seller:)
    policy = policy_class.new(context, :record)

    assert_nil policy.user
    assert_equal seller, policy.seller
    assert_equal :record, policy.record
  end

  test "#initialize works normally when user is present and anonymous access is allowed" do
    user = users(:basic_user)
    seller = users(:named_seller)
    policy_class = Class.new(ApplicationPolicy) { allow_anonymous_user_access! }
    context = SellerContext.new(user:, seller:)
    policy = policy_class.new(context, :record)

    assert_equal user, policy.user
    assert_equal seller, policy.seller
    assert_equal :record, policy.record
  end
end
