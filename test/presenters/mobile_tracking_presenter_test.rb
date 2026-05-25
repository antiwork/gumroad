# frozen_string_literal: true

require "test_helper"

class MobileTrackingPresenterTest < ActiveSupport::TestCase
  setup do
    @seller = users(:named_seller)
    @product = links(:named_seller_product)
    @presenter = MobileTrackingPresenter.new(seller: @seller)
  end

  test "#product_props returns the correct props" do
    assert_equal(
      {
        seller_id: @seller.external_id,
        analytics: {
          google_analytics_id: nil,
          facebook_pixel_id: nil,
          tiktok_pixel_id: nil,
          free_sales: true,
        },
        has_product_third_party_analytics: false,
        has_receipt_third_party_analytics: false,
        third_party_analytics_domain: THIRD_PARTY_ANALYTICS_DOMAIN,
        permalink: @product.unique_permalink,
        name: @product.name,
      },
      @presenter.product_props(product: @product)
    )
  end

  test "returns has_product_third_party_analytics: true when seller has product-location analytics" do
    ThirdPartyAnalytic.create!(user: @seller, link: @product, location: "product", analytics_code: "<script></script>")

    props = @presenter.product_props(product: @product)
    assert_equal true, props[:has_product_third_party_analytics]
    assert_equal false, props[:has_receipt_third_party_analytics]
  end

  test "returns has_receipt_third_party_analytics: true when seller has receipt-location analytics" do
    ThirdPartyAnalytic.create!(user: @seller, link: @product, location: "receipt", analytics_code: "<script></script>")

    props = @presenter.product_props(product: @product)
    assert_equal false, props[:has_product_third_party_analytics]
    assert_equal true, props[:has_receipt_third_party_analytics]
  end

  test "returns both as true when seller has all-location analytics" do
    ThirdPartyAnalytic.create!(user: @seller, link: @product, location: "all", analytics_code: "<script></script>")

    props = @presenter.product_props(product: @product)
    assert_equal true, props[:has_product_third_party_analytics]
    assert_equal true, props[:has_receipt_third_party_analytics]
  end
end
