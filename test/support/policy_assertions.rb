# frozen_string_literal: true

# Shared assertions for Pundit policies that share the standard seller +
# 4-role-team-member shape (see test/fixtures/users.yml `named_seller` and
# friends). Each helper takes a list of actions and asserts permit/deny for
# the given role fixture against ALL of them — matches RSpec
# `permissions :a, :b do ... end` semantics.
module PolicyAssertions
  # Helper to build the SellerContext for a fixture user.
  def policy_context(user_fixture)
    SellerContext.new(user: users(user_fixture), seller: users(:named_seller))
  end

  def assert_policy_permits(policy_class, record, user_fixture, *actions)
    actions.each do |action|
      assert policy_class.new(policy_context(user_fixture), record).public_send(action),
             "expected #{policy_class}##{action} to permit #{user_fixture}"
    end
  end

  def refute_policy_permits(policy_class, record, user_fixture, *actions)
    actions.each do |action|
      assert_not policy_class.new(policy_context(user_fixture), record).public_send(action),
                 "expected #{policy_class}##{action} to deny #{user_fixture}"
    end
  end
end
