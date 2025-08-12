# frozen_string_literal: true

class Purchase::AssociateBundleProductLevelGiftService
  def initialize(bundle_purchase:, bundle_product:)
    @bundle_purchase = bundle_purchase
    @bundle_product = bundle_product
  end

  def perform
    return unless bundle_product_belongs_to_bundle?
    return if bundle_level_gift.blank?

    product_level_gift = existing_product_level_gift || Gift.new
    product_level_gift.update!(product_level_gift_params)
  end

  private
    def bundle_product_belongs_to_bundle?
      @bundle_product.bundle_id == @bundle_purchase.link_id
    end

    def existing_product_level_gift
      query = Gift.none

      if gift_sender_bundle_product_purchase.present?
        query = query.or(Gift.where(gifter_purchase: gift_sender_bundle_product_purchase))
      end

      if gift_receiver_bundle_product_purchase.present?
        query = query.or(Gift.where(giftee_purchase: gift_receiver_bundle_product_purchase))
      end

      query.first
    end

    def product_level_gift_params
      bundle_level_gift.attributes
        .except("id", "created_at", "updated_at")
        .merge(
          giftee_purchase: gift_receiver_bundle_product_purchase,
          gifter_purchase: gift_sender_bundle_product_purchase,
          link_id: @bundle_product.product_id,
        )
    end

    def bundle_level_gift
      @bundle_level_gift ||= @bundle_purchase.gift
    end

    def gift_sender_bundle_purchase
      @gift_sender_bundle_purchase ||= bundle_level_gift.gifter_purchase
    end

    def gift_receiver_bundle_purchase
      @gift_receiver_bundle_purchase ||= bundle_level_gift.giftee_purchase
    end

    def gift_sender_bundle_product_purchase
      @gift_sender_bundle_product_purchase ||= gift_sender_bundle_purchase
        .product_purchases
        .find_by(link_id: @bundle_product.product_id)
    end

    def gift_receiver_bundle_product_purchase
      @gift_receiver_bundle_product_purchase ||= gift_receiver_bundle_purchase
        .product_purchases
        .find_by(link_id: @bundle_product.product_id)
    end
end
