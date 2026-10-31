# frozen_string_literal: true

class RecommendedProducts::CheckoutService < RecommendedProducts::BaseService
  def self.fetch_for_cart(purchaser:, cart_product_ids:, recommender_model_name:, limit:, recommendation_type: nil, prefer_paid_products: false)
    new(
      purchaser:,
      cart_product_ids:,
      recommender_model_name:,
      recommended_by: RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION,
      target: Product::Layout::PROFILE,
      limit: [limit, Link::MAX_RESULT_WINDOW].min,
      recommendation_type:,
    ).result(prefer_paid_products:)
  end

  def self.fetch_for_receipt(purchaser:, receipt_product_ids:, recommender_model_name:, limit:)
    new(
      purchaser:,
      cart_product_ids: receipt_product_ids,
      recommender_model_name:,
      recommended_by: RecommendationType::GUMROAD_RECEIPT_RECOMMENDATION,
      target: Product::Layout::PROFILE,
      limit:,
    ).result
  end

  include SearchProducts

  FREE_RESULTS_HEADROOM = 2
  PAID_MIN_PRICE = "0.01"
  # A fully discounted product keeps its list price, so it passes PAID_MIN_PRICE and comes back from
  # the paid-only search as a free result. Enough of them ahead in the featured order fill one search
  # window with no paid product at all, so each pass excludes what it has already looked at and
  # searches further down. Bounded, because the checkout page cannot pay for unlimited searches.
  MAX_PAID_SEARCH_PASSES = 3

  # Only the checkout row asks for paid-first ordering: it sits directly under the cart, so a free
  # product there advertises a $0 alternative at the moment of payment. Receipt emails and the
  # post-purchase "More like this" block keep the raw co-purchase ranking, where a free lead magnet
  # is a legitimate next step.
  def result(prefer_paid_products: false)
    recommended_products = fetch_recommended_products(for_seller_ids: affiliated_users.present? ? nil : cart_seller_ids)
    recommended_products = recommended_products.includes(:direct_affiliates) if affiliated_users.present?
    recommended_products = recommended_products.includes(:taxonomy, user: [:alive_bank_accounts]) if global_affiliate.present?
    recommended_products = recommended_products.alive.not_archived.includes(ProductPresenter::ASSOCIATIONS_FOR_CARD)
    recommended_products = recommended_products.reject(&:rated_as_adult?) if affiliated_users.present? && Link.includes(:user).where(id: cart_product_ids).none?(&:rated_as_adult?)

    product_infos = recommended_products.filter_map do |product|
      direct_affiliate_id = affiliated_users.present? ? product.direct_affiliates.find { affiliated_users.ids.include?(_1.affiliate_user_id) }&.external_id_numeric : nil

      if cart_seller_ids&.include?(product.user_id) || direct_affiliate_id.present? || (global_affiliate.present? && product.user.not_disable_global_affiliate? && product.recommendable?)
        RecommendedProducts::ProductInfo.new(
          product,
          source: RecommendedProducts::ProductInfo::CO_PURCHASE,
          affiliate_id: direct_affiliate_id || global_affiliate&.external_id_numeric
        )
      end
    end
    product_infos = prefer_paid_products ? fill_paid_first(product_infos) : fill_in_order(product_infos)

    build_result(product_infos:)
  end

  private
    def fill_in_order(product_infos)
      product_infos = product_infos.take(limit)
      return product_infos if product_infos.length >= limit || cart_seller_ids.blank?

      product_infos + search_creator_featured(size: limit - product_infos.length, exclude_ids: product_infos.map { _1.product.id })
    end

    # Paid products take every slot they can, searching paid-only before free ones fill the rest.
    def fill_paid_first(product_infos)
      paid, free = product_infos.partition { !free_product?(_1.product) }
      selected = paid.take(limit)
      considered_ids = product_infos.map { _1.product.id }

      MAX_PAID_SEARCH_PASSES.times do
        break if selected.length >= limit || cart_seller_ids.blank?

        # search_options raises on a window past MAX_RESULT_WINDOW.
        size = [(limit - selected.length) * FREE_RESULTS_HEADROOM, Link::MAX_RESULT_WINDOW].min
        found = search_creator_featured(
          size:,
          exclude_ids: considered_ids,
          min_price: PAID_MIN_PRICE
        )

        found_paid, found_free = found.partition { !free_product?(_1.product) }
        selected += found_paid.take(limit - selected.length)
        free += found_free
        considered_ids += found.map { _1.product.id }
        # A short window means nothing priced is left further down.
        break if found.length < size
      end

      selected += free.take(limit - selected.length)

      if selected.length < limit && cart_seller_ids.present?
        taken_ids = (product_infos + selected).map { _1.product.id }
        selected += search_creator_featured(size: limit - selected.length, exclude_ids: taken_ids)
      end

      selected
    end

    def search_creator_featured(size:, exclude_ids:, min_price: nil)
      options = {
        size:,
        sort: ProductSortKey::FEATURED,
        user_id: cart_seller_ids,
        is_alive_on_profile: true,
        exclude_ids: (exclude_product_ids + exclude_ids).uniq
      }
      options[:min_price] = min_price if min_price
      products = search_products(options)[:products].includes(ProductPresenter::ASSOCIATIONS_FOR_CARD)
      products.map { RecommendedProducts::ProductInfo.new(_1, source: RecommendedProducts::ProductInfo::CREATOR_FEATURED) }
    end

    # Free means the price the buyer sees on the card, discount included.
    def free_product?(product)
      base_price_cents = product.display_price_cents(for_default_duration: true)
      product.discounted_price_cents(base_price_cents).to_i.zero?
    end

    def cart_seller_ids
      return [] if recommendation_type == User::RecommendationType::NO_RECOMMENDATIONS
      @_seller_ids ||= begin
        users = Link.joins(:user)
        users = users.where.not(user: { recommendation_type: User::RecommendationType::NO_RECOMMENDATIONS }) if !recommendation_type
        users
          .where(id: cart_product_ids)
          .select(:user_id)
          .distinct
          .pluck(:user_id)
      end
    end

    def affiliated_users
      @_affiliate_users ||= begin
        recommendation_types = [
          User::RecommendationType::GUMROAD_AFFILIATES_PRODUCTS,
          User::RecommendationType::DIRECTLY_AFFILIATED_PRODUCTS
        ]
        return User.none if cart_seller_ids.blank? || recommendation_type && !recommendation_types.include?(recommendation_type)

        users = User.where(id: cart_seller_ids)
        users = users.where(recommendation_type: recommendation_types) if !recommendation_type
        users
      end
    end

    def global_affiliate
      @_global_affiliate ||= affiliated_users
        .find { (recommendation_type || _1.recommendation_type) == User::RecommendationType::GUMROAD_AFFILIATES_PRODUCTS }
        &.global_affiliate
    end
end
