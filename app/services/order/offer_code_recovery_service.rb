# frozen_string_literal: true

class Order::OfferCodeRecoveryService
  FAILED_PURCHASE_STATES = %w[failed preorder_authorization_failed gift_receiver_purchase_failed].freeze
  MAX_RETRY_OFFER_CODES = 10
  MAX_RETRY_OFFER_CODE_PRODUCTS = 100
  MAX_RETRY_OFFER_CODE_FIELD_BYTES = 255

  def self.merge_responses(*response_groups)
    response_groups.flatten.each_with_object({}) do |response, merged|
      key = response[:code].to_s.strip.downcase
      if merged.key?(key)
        merged[key][:products].merge!(response[:products])
      else
        merged[key] = { code: response[:code], products: response[:products].dup }
      end
    end.values
  end

  def self.for_order(order)
    return [] unless order.persisted?

    failed_purchases = order.purchases.reload.select { FAILED_PURCHASE_STATES.include?(_1.purchase_state) }
    new(order:, failed_purchases:).perform
  end

  def self.sanitize_retry_candidates(raw_candidates)
    candidates = raw_candidates.is_a?(Array) ? raw_candidates : []
    return [] if candidates.size > MAX_RETRY_OFFER_CODES

    total_products = 0
    candidates.each_with_object([]) do |candidate, sanitized|
      return [] unless candidate.respond_to?(:key?) && candidate.respond_to?(:[])

      code = candidate[:code].to_s.strip.downcase
      product_params = candidate[:products]
      return [] if code.blank? || code.bytesize > MAX_RETRY_OFFER_CODE_FIELD_BYTES
      return [] unless product_params.respond_to?(:each_pair) && product_params.respond_to?(:size)

      total_products += product_params.size
      return [] if total_products > MAX_RETRY_OFFER_CODE_PRODUCTS

      products = product_params.each_pair.with_object({}) do |(line_item_uid, product), result|
        return [] unless product.respond_to?(:key?) && product.respond_to?(:[])

        line_item_uid = line_item_uid.to_s
        permalink = product[:permalink].to_s
        quantity = Integer(product[:quantity], exception: false)
        return [] if line_item_uid.blank? || permalink.blank? || quantity.nil? || quantity <= 0
        return [] if line_item_uid.bytesize > MAX_RETRY_OFFER_CODE_FIELD_BYTES ||
          permalink.bytesize > MAX_RETRY_OFFER_CODE_FIELD_BYTES

        result[line_item_uid] = { permalink:, quantity: }
      end
      sanitized << { code:, products: }
    end
  end

  def self.revalidate_retry_candidates(order:, candidates:)
    candidates.filter_map do |candidate|
      service = OfferCodeDiscountComputingService.new(
        candidate[:code],
        candidate[:products],
        buyer: order.purchaser,
        key_by_input: true
      )
      result = service.process
      next if result[:error_code].present?

      discounts = result[:products_data].to_h do |line_item_uid, data|
        [candidate[:products].fetch(line_item_uid)[:permalink], data[:discount]]
      end
      { code: candidate[:code], products: discounts } if discounts.any?
    end
  end

  def initialize(order:, failed_purchases:)
    @order = order
    @failed_purchases = failed_purchases
  end

  def perform
    return [] if failed_purchases.empty?

    once_per_cart_codes.filter_map do |offer_code|
      result = OfferCodeDiscountComputingService.new(
        offer_code.code,
        products,
        buyer: order.purchaser,
        key_by_input: true,
        excluding_purchases: unresolved_purchases
      ).process
      next if result[:error_code].present?
      next if (result[:products_data].keys & failed_purchases.map { _1.id.to_s }).empty?

      {
        code: offer_code.code,
        products: result[:products_data].each_with_object({}) do |(purchase_id, data), discounts|
          purchase = purchases_by_id.fetch(purchase_id)
          discounts[purchase.link.unique_permalink] ||= data[:discount]
        end,
      }
    end
  end

  private
    attr_reader :order, :failed_purchases

    def once_per_cart_codes
      order.purchases.filter_map do |purchase|
        purchase.offer_code if purchase.purchase_offer_code_discount&.once_per_cart?
      end.uniq { _1.code.downcase }
    end

    def products
      @products ||= unresolved_purchases.to_h do |purchase|
        [purchase.id.to_s, { permalink: purchase.link.unique_permalink, quantity: purchase.quantity }]
      end
    end

    def unresolved_purchases
      @unresolved_purchases ||= order.purchases.reject do |purchase|
        Purchase::ALL_SUCCESS_STATES_INCLUDING_TEST.include?(purchase.purchase_state)
      end
    end

    def purchases_by_id
      @purchases_by_id ||= order.purchases.index_by { _1.id.to_s }
    end
end
