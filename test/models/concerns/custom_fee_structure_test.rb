require "test_helper"

class CustomFeeStructureTest < ActiveSupport::TestCase
  setup do
    @user = users(:seller)
    @product = @user.products.first || create(:product, user: @user)
  end

  test "uses custom direct fee when set" do
    @user.update!(custom_direct_fee_percentage: 8.5)
    
    purchase = Purchase.new(
      seller: @user,
      price_cents: 1000, # $10.00
      link: @product
    )
    
    purchase.send(:calculate_fees)
    
    # 8.5% of $10.00 = 85 cents
    assert_equal 85, purchase.fee_cents
  end

  test "uses default fee when custom fee is not set" do
    @user.update!(custom_direct_fee_percentage: nil)
    
    purchase = Purchase.new(
      seller: @user,
      price_cents: 1000, # $10.00
      link: @product
    )
    
    purchase.send(:calculate_fees)
    
    # Should use default fee (10% = 100 cents)
    assert_equal 100, purchase.fee_cents
  end

  test "uses custom discover fee when set" do
    @user.update!(custom_discover_fee_percentage: 25.0)
    
    purchase = Purchase.new(
      seller: @user,
      price_cents: 1000,
      link: @product,
      recommended_by: RecommendationType::GUMROAD_RECEIPT_RECOMMENDATION
    )
    
    discover_fee = purchase.send(:calculate_additional_discover_fee_per_thousand)
    
    # 25% = 250 per thousand
    assert_equal 250, discover_fee
  end
end
