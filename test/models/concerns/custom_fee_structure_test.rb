require "test_helper"

class CustomFeeStructureTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      name: "Test Seller",
      email: "seller#{rand(100000)}@example.com",
      password: "SecureTestPassword#{rand(10000)}!"
    )
    @product = @user.products.create!(
      name: "Test Product",
      price_cents: 1000
    )
  end

  # Direct Fee Tests
  test "uses custom direct fee when set" do
    @user.update!(custom_direct_fee_percentage: 8.5)
    
    purchase = Purchase.new(
      seller: @user,
      price_cents: 1000,
      link: @product
    )
    
    purchase.send(:calculate_fees)
    assert_equal 85, purchase.fee_cents
  end

  test "uses default direct fee when custom fee is nil" do
    @user.update!(custom_direct_fee_percentage: nil)
    
    purchase = Purchase.new(
      seller: @user,
      price_cents: 1000,
      link: @product
    )
    
    purchase.send(:calculate_fees)
    assert_equal 100, purchase.fee_cents
  end

  # Discover Fee Tests
  test "custom discover fee calculates additional amount correctly" do
    @user.update!(custom_discover_fee_percentage: 25.0)
    
    purchase = Purchase.new(
      seller: @user,
      price_cents: 1000,
      link: @product
    )
    
    additional_fee = purchase.send(:calculate_additional_discover_fee_per_thousand)
    
    # Should return additional amount, not full 250
    assert additional_fee < 250
    assert additional_fee >= 0
  end

  # Validation Tests  
  test "validates custom direct fee percentage range" do
    user = User.new(name: "Test", email: "test#{rand(100000)}@example.com")
    
    user.custom_direct_fee_percentage = -1
    assert_not user.valid?
    assert user.errors[:custom_direct_fee_percentage].any?
    
    user.custom_direct_fee_percentage = 51
    assert_not user.valid?
    assert user.errors[:custom_direct_fee_percentage].any?
    
    user.custom_direct_fee_percentage = 25
    user.validate
    assert_empty user.errors[:custom_direct_fee_percentage]
  end

  test "validates custom discover fee percentage range" do
    user = User.new(name: "Test", email: "test#{rand(100000)}@example.com")
    
    user.custom_discover_fee_percentage = -1
    assert_not user.valid?
    assert user.errors[:custom_discover_fee_percentage].any?
    
    user.custom_discover_fee_percentage = 101
    assert_not user.valid?
    assert user.errors[:custom_discover_fee_percentage].any?
    
    user.custom_discover_fee_percentage = 50
    user.validate
    assert_empty user.errors[:custom_discover_fee_percentage]
  end

  # Edge Cases
  test "handles zero custom fees" do
    @user.update!(custom_direct_fee_percentage: 0)
    
    purchase = Purchase.new(
      seller: @user,
      price_cents: 1000,
      link: @product
    )
    
    purchase.send(:calculate_fees)
    assert_equal 0, purchase.fee_cents
  end
end
