# frozen_string_literal: true

module ProductPageViewHelpers
  def add_page_view(product, timestamp = Time.current.iso8601, extra_body = {})
    extra_body[:referrer_domain] = extra_body[:referrer_domain].presence || "direct"
    EsClient.index(
      index: ProductPageView.index_name,
      body: {
        product_id: product.id,
        seller_id: product.user_id,
        timestamp:
      }.merge(extra_body)
    )
  end
end
