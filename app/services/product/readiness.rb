# frozen_string_literal: true

module Product
  module Readiness
    NORMAL_LIFECYCLE_STATES = %w[draft ready live].freeze

    def self.for(product:, seller_can_publish_products:)
      return nil if product.is_recurring_billing?
      return nil if product.is_in_preorder_state?
      return nil if product.archived?
      return nil if product.banned_at.present?
      return nil if product.purchase_disabled_at.present?

      if product.published? && product.alive?
        return { "state" => "live", "missing" => [] }
      end

      missing = []
      missing << "name" if product.name.blank?
      missing << "price" if product.price_cents.nil?
      missing << "content" unless product.has_content?
      missing << "cover" if product.thumbnail_or_cover_url.blank?
      missing << "payment" unless seller_can_publish_products

      { "state" => missing.empty? ? "ready" : "draft", "missing" => missing }
    end
  end
end
