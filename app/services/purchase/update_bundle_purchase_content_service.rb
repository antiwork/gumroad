# frozen_string_literal: true

class Purchase::UpdateBundlePurchaseContentService
  def initialize(purchase)
    @purchase = purchase
  end

  def perform
    existing_product_ids = @purchase.product_purchases.pluck(:link_id)

    purchases = @purchase.link
      .bundle_products
      .alive
      .where.not(product_id: existing_product_ids)
      .map do |bundle_product|
      Purchase::CreateBundleProductPurchaseService.new(@purchase, bundle_product).perform
    end

    CustomerLowPriorityMailer.bundle_content_updated(@purchase.id).deliver_later if purchases.present?
  end
end
