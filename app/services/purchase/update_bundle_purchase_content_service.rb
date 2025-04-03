# frozen_string_literal: true

class Purchase::UpdateBundlePurchaseContentService
  def initialize(purchase)
    @purchase = purchase
  end

  def perform
    existing_product_purchases = @purchase.product_purchases.pluck(:created_at, :link_id)
    content_needed_after = existing_product_purchases.map(&:first).max

    purchases = @purchase.link
      .bundle_products
      .alive
      .where(updated_at: content_needed_after..)
      .where.not(product_id: existing_product_purchases.map(&:second))
      .map do |bundle_product|
      Purchase::CreateBundleProductPurchaseService.new(@purchase, bundle_product).perform
    end

    CustomerLowPriorityMailer.bundle_content_updated(@purchase.id).deliver_later if purchases.present?
  end
end
