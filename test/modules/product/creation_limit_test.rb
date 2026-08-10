# frozen_string_literal: true

require "test_helper"

class Product::CreationLimitTest < ActiveSupport::TestCase
  setup do
    # test_helper's global setup bypasses this limit for every test (so unrelated tests
    # that create many products don't hit the 10/day cap). This suite exists specifically
    # to exercise the limit, so turn the bypass back off for it.
    ActiveSupport::IsolatedExecutionState[:gumroad_bypass_product_creation_limit] = false

    @seller = create_user
    @seller.stubs(:compliant?).returns(false)
  end

  test "counts alive products created in the last 24 hours toward the limit" do
    9.times { create_product(user: @seller) }

    assert_difference -> { @seller.links.count }, 1 do
      create_product(user: @seller)
    end

    assert_raises(ActiveRecord::RecordInvalid) { create_product(user: @seller) }
  end

  test "deleting a product frees up quota" do
    products = Array.new(10) { create_product(user: @seller) }

    assert_raises(ActiveRecord::RecordInvalid) { create_product(user: @seller) }

    products.first.mark_deleted!

    assert_nothing_raised { create_product(user: @seller) }
  end

  test "compliant accounts get the higher 100/day limit" do
    @seller.stubs(:compliant?).returns(true)
    99.times { create_product(user: @seller) }

    assert_nothing_raised { create_product(user: @seller) }
    assert_raises(ActiveRecord::RecordInvalid) { create_product(user: @seller) }
  end

  test "team members bypass the limit entirely" do
    @seller.stubs(:is_team_member?).returns(true)
    11.times { create_product(user: @seller) }

    assert_equal 11, @seller.links.count
  end
end
