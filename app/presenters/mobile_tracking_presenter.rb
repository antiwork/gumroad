# frozen_string_literal: true

class MobileTrackingPresenter
  include UsersHelper

  attr_reader :seller

  def initialize(seller:)
    @seller = seller
  end

  def product_props(product:)
    {
      seller_id: seller.external_id,
      analytics: product.analytics_data,
      has_product_third_party_analytics: product.has_third_party_analytics?("product"),
      has_receipt_third_party_analytics: product.has_third_party_analytics?("receipt"),
      third_party_analytics_domain: THIRD_PARTY_ANALYTICS_DOMAIN,
      permalink: product.unique_permalink,
      name: product.name
    }
  end
end
