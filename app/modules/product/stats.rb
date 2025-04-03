# frozen_string_literal: true

module Product::Stats
  extend ActiveSupport::Concern

  class_methods do
    # Essentially returns a sum of "active customers" (for each product)
    # because we're considering each subscription as one sale,
    # and excluding deactivated subscription.
    def successful_sales_count(products:, extra_search_options: nil)
      return 0 if products.blank?

      search_options = Purchase::ACTIVE_SALES_SEARCH_OPTIONS.merge(
        product: products,
        size: 0,
        track_total_hits: true,
      )
      search_options.merge!(extra_search_options) if extra_search_options.present?
      PurchaseSearchService.search(search_options).results.total
    end

    def monthly_recurring_revenue(products:)
      return 0 if products.blank?

      search_options = {
        product: products,
        state: Purchase::NON_GIFT_SUCCESS_STATES,
        exclude_non_original_subscription_purchases: true,
        exclude_deactivated_subscriptions: true,
        exclude_cancelled_or_pending_cancellation_subscriptions: true,
        exclude_bundle_product_purchases: true,
        aggs: { mrr_total: { sum: { field: "monthly_recurring_revenue" } } },
        size: 0
      }
      search_result = PurchaseSearchService.search(search_options)
      search_result.aggregations.mrr_total.value
    end
  end

  def successful_sales_count(extra_search_options = nil)
    self.class.successful_sales_count(products: self, extra_search_options:)
  end

  def has_successful_sales?
    successful_sales_count(track_total_hits: nil) > 0
  end

  def sales_unit
    if is_recurring_billing
      "subscribers"
    elsif is_in_preorder_state
      "preorders"
    else
      "sales"
    end
  end

  def balance_formatted(total_cents = nil)
    Money.new(total_cents || total_usd_cents).format(no_cents_if_whole: true)
  end

  def pending_balance
    subscriptions.active.find_each.inject(0) { |total, sub| total + sub.remaining_charges_count * sub.original_purchase.price_cents }
  end

  def revenue_pending
    duration_in_months? ? pending_balance : 0
  end

  def monthly_recurring_revenue
    self.class.monthly_recurring_revenue(products: self)
  end

  def total_usd_cents(extra_search_options = {})
    search_options = Purchase::CHARGED_SALES_SEARCH_OPTIONS.merge(
      product: self,
      size: 0,
      aggs: {
        price_cents_total: { sum: { field: "price_cents" } },
        amount_refunded_cents_total: { sum: { field: "amount_refunded_cents" } },
      }
    ).merge(extra_search_options)
    search_result = PurchaseSearchService.search(search_options)
    search_result.aggregations.price_cents_total.value - search_result.aggregations.amount_refunded_cents_total.value
  end

  def total_usd_cents_earned_by_user(for_user, extra_search_options = {})
    for_seller = for_user.id == user.id
    search_options = Purchase::CHARGED_SALES_SEARCH_OPTIONS.merge(
      product: self,
      size: 0,
      aggs: {
        price_cents_total: { sum: { field: "price_cents" } },
        affiliate_cents_total: { sum: { field: "affiliate_credit_amount_cents" } },
        affiliate_fees_total: { sum: { field: "affiliate_credit_fee_cents" } },
        amount_refunded_cents_total: { sum: { field: for_seller ? "amount_refunded_cents" : "affiliate_credit_amount_partially_refunded_cents" } },
      }
    ).merge(extra_search_options)
    if for_seller
      search_options[:seller] = for_user
    else
      search_options[:affiliate_user] = for_user
    end
    search_result = PurchaseSearchService.search(search_options)

    affiliate_total = search_result.aggregations.affiliate_cents_total.value + search_result.aggregations.affiliate_fees_total.value - search_result.aggregations.amount_refunded_cents_total.value
    if for_seller
      search_result.aggregations.price_cents_total.value - affiliate_total
    else
      affiliate_total
    end
  end

  def total_fee_cents(extra_search_options = {})
    search_options = Purchase::CHARGED_SALES_SEARCH_OPTIONS.merge(
      product: self,
      size: 0,
      aggs: {
        fee_cents_total: { sum: { field: "fee_cents" } },
        fee_refunded_cents_total: { sum: { field: "fee_refunded_cents" } },
      }
    ).merge(extra_search_options)
    search_result = PurchaseSearchService.search(search_options)
    search_result.aggregations.fee_cents_total.value - search_result.aggregations.fee_refunded_cents_total.value
  end

  def number_of_views
    EsClient.count(index: ProductPageView.index_name, body: { query: { term: { product_id: id } } })["count"]
  end

  def active_customers_count
    PurchaseSearchService.search(
      product: self,
      state: Purchase::ALL_SUCCESS_STATES_EXCEPT_PREORDER_AUTH,
      exclude_giftees: true,
      exclude_refunded_except_subscriptions: true,
      exclude_deactivated_subscriptions: true,
      exclude_unreversed_chargedback: true,
      exclude_non_original_subscription_purchases: true,
      exclude_commission_completion_purchases: true,
      exclude_bundle_product_purchases: true,
      size: 0,
      aggs: { unique_email_count: { cardinality: { field: "email.raw" } } }
    ).aggregations.unique_email_count.value
  end
end
