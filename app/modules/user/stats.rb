# frozen_string_literal: true

# Mixin contains stats helpers for use on Users.
#
# See the User::PaymentStats module for internal stats that are not displayed to the Seller.
module User::Stats
  include CurrencyHelper
  extend ActiveSupport::Concern

  included do
    attr_accessor :sales_total

    scope :by_sales_revenue, lambda { |days_ago: nil, limit:|
      joins("LEFT JOIN links on links.user_id = users.id \
           LEFT JOIN purchases on purchases.link_id = links.id")
        .select("users.*, SUM(purchases.price_cents) AS sales_total")
        .where("purchases.price_cents > 0  AND purchases.purchase_state = 'successful' AND \
               (purchases.stripe_refunded IS NULL OR purchases.stripe_refunded = 0) \
               #{days_ago.present? ? ' AND purchases.created_at > ?' : ''}", days_ago.to_i.days.ago)
        .group("users.id")
        .order("sales_total DESC, users.created_at DESC")
        .limit(limit)
    }
  end

  def active_subscribers?(charge_processor_id:, merchant_account: nil)
    active_subscriptions = Subscription.distinct
                                       .joins(link: :user)
                                       .merge(Link.alive.is_recurring_billing)
                                       .where(users: { id: })
                                       .active_without_pending_cancel
                                       .joins(:purchases)
                                       .where.not(purchases: { total_transaction_cents: 0 })

    active_subscriptions = active_subscriptions.where("purchases.merchant_account_id = ?", merchant_account.id) if merchant_account.present?

    subscriptions_using_charge_processor = false
    subscriptions_using_charge_processor ||= active_subscriptions.where(user_id: nil)
                                                                 .joins(:credit_card)
                                                                 .where(credit_cards: { charge_processor_id: })
                                                                 .exists?
    subscriptions_using_charge_processor ||= active_subscriptions.where.not(user_id: nil)
                                                                 .joins(user: :credit_card)
                                                                 .where(credit_cards: { charge_processor_id: })
                                                                 .exists?
    subscriptions_using_charge_processor
  end

  def active_preorders?(charge_processor_id:, merchant_account: nil)
    preorders = Preorder.distinct.joins(preorder_link: { link: :user })
                        .merge(Link.alive.is_in_preorder_state)
                        .merge(PreorderLink.without_state(:released))
                        .authorization_successful
                        .where(users: { id: })
                        .joins(:purchases)
                        .where.not(purchases: { total_transaction_cents: 0 })

    preorders = preorders.where("purchases.merchant_account_id = ?", merchant_account.id) if merchant_account.present?

    preorders_using_charge_processor = false
    preorders_using_charge_processor ||= preorders.where(purchaser_id: nil)
                                          .joins(:credit_card)
                                          .where(credit_cards: { charge_processor_id: })
                                          .exists?
    preorders_using_charge_processor ||= preorders.where.not(purchaser_id: nil)
                                          .joins(purchaser: :credit_card)
                                          .where(credit_cards: { charge_processor_id: })
                                          .exists?
    preorders_using_charge_processor
  end

  def balance_formatted(via: :sql)
    formatted_dollar_amount(unpaid_balance_cents(via:), with_currency: should_be_shown_currencies_always?)
  end

  def affiliate_credits_sum_for_credits_created_between(start_time, end_time)
    paid_scope = affiliate_credits.paid.where("affiliate_credits.created_at > ? AND affiliate_credits.created_at <= ? ", start_time, end_time)
    all_scope = affiliate_credits.where("affiliate_credits.created_at > ? AND affiliate_credits.created_at <= ? ", start_time, end_time)
    affiliate_credit_sum_from_scope(paid_scope, all_scope)
  end

  def affiliate_credits_sum_total
    paid_scope = affiliate_credits.paid
    all_scope = affiliate_credits
    affiliate_credit_sum_from_scope(paid_scope, all_scope)
  end

  def affiliate_credit_sum_from_scope(paid_scope, all_scope)
    aff_credit_cents = paid_scope.sum("amount_cents").to_i
    aff_credit_cents += all_scope
                            .joins(:purchase).where("purchases.stripe_partially_refunded": true)
                            .sum("amount_cents")
    aff_credit_cents -= all_scope
                            .joins(:purchase).where("purchases.stripe_partially_refunded": true)
                            .joins(:affiliate_partial_refunds)
                            .sum("affiliate_partial_refunds.amount_cents")
    aff_credit_cents
  end

  def last_weeks_followers
    end_of_period = Date.today.beginning_of_week(:sunday).to_datetime
    start_of_period = end_of_period - 7.days
    followers.active.where("created_at > ? and created_at <= ?", start_of_period, end_of_period).count
  end

  def last_weeks_sales
    end_of_period = Date.today.beginning_of_week(:sunday).to_datetime
    start_of_period = end_of_period - 7.days
    paid_sales = sales.paid.not_chargedback_or_chargedback_reversed
                     .where("purchases.created_at > ? and purchases.created_at <= ?", start_of_period, end_of_period)
    total_from(paid_sales, affiliate_credits_sum_for_credits_created_between(start_of_period, end_of_period))
  end

  def total_from(paid_sales, affiliate_credits)
    price = paid_sales.sum(:price_cents)
    price += affiliate_credits
    fee = paid_sales.sum(:fee_cents)
    fee += paid_sales.sum(:affiliate_credit_cents)
    price -= paid_sales.joins(:refunds).sum("refunds.amount_cents")
    fee -= paid_sales.joins(:refunds).sum("refunds.fee_cents")
    fee -= paid_sales.joins(:affiliate_partial_refunds).sum("affiliate_partial_refunds.amount_cents")
    price - fee
  end

  def credits_total
    credits.sum(:amount_cents)
  end

  def sales_cents_total(after: nil)
    revenue_as_seller(after:) + revenue_as_affiliate(after:)
  end

  def gross_sales_cents_total_as_seller(recommended: nil)
    search_params = Purchase::CHARGED_SALES_SEARCH_OPTIONS.merge(
      seller: self,
      recommended:,
      size: 0,
      aggs: {
        price_cents_total: { sum: { field: "price_cents" } },
        amount_refunded_cents_total: { sum: { field: "amount_refunded_cents" } },
      },
    )

    result = PurchaseSearchService.search(search_params)
    result.aggregations.price_cents_total.value - result.aggregations.amount_refunded_cents_total.value
  end

  def sales_cents_total_formatted
    formatted_dollar_amount(sales_cents_total, with_currency: should_be_shown_currencies_always?)
  end

  def time_until_pay_day_formatted
    end_time = DateTime.current.end_of_month
    stamp = end_time.strftime("#{end_time.day.ordinalize} of %B")
    if end_time > 1.day.from_now
      days = (end_time - DateTime.current).to_i
      "in #{days} days, on the #{stamp}"
    else
      "on the #{stamp}"
    end
  end

  # Admin use only
  def lost_chargebacks # returns `{ volume: String, count: String }`
    search_params = {
      seller: self,
      state: "successful",
      exclude_refunded: true,
      exclude_bundle_product_purchases: true,
      track_total_hits: true,
      aggs: {
        price_cents_total: { sum: { field: "price_cents" } },
        unreversed_chargebacks: {
          filter: {
            bool: {
              must: [{ exists: { field: "chargeback_date" } }],
              must_not: [{ term: { "selected_flags" => "chargeback_reversed" } }]
            }
          },
          aggs: {
            price_cents_total: { sum: { field: "price_cents" } }
          }
        }
      }
    }
    search_result = PurchaseSearchService.search(search_params)
    count_denominator = search_result.response.hits.total.value.to_f
    volume_denominator = search_result.aggregations["price_cents_total"]["value"]
    count_numerator = search_result.aggregations["unreversed_chargebacks"]["doc_count"].to_f
    volume_numerator = search_result.aggregations["unreversed_chargebacks"]["price_cents_total"]["value"]
    volume = volume_denominator > 0 ? format("%.1f%%", volume_numerator / volume_denominator * 100) : "NA"
    count = count_denominator > 0 ? format("%.1f%%", count_numerator / count_denominator * 100) : "NA"
    { volume:, count: }
  end

  def sales_cents_for_balances(balance_ids)
    sales
      .where(purchase_success_balance_id: balance_ids)
      .sum("price_cents")
  end

  def refunds_cents_for_balances(balance_ids)
    sales.where(purchase_refund_balance_id: balance_ids)
        .joins(:refunds).sum("refunds.amount_cents")
  end

  def chargebacks_cents_for_balances(balance_ids)
    chargebacked_sales = sales.where(purchase_chargeback_balance_id: balance_ids)
    chargebacked_sales.sum("price_cents") - chargebacked_sales.joins(:refunds).sum("refunds.amount_cents")
  end

  def credits_cents_for_balances(balance_ids)
    credits
      .where(financing_paydown_purchase_id: nil)
      .where("json_data->>'$.stripe_loan_paydown_id' IS NULL")
      .where(fee_retention_refund_id: nil)
      .where(balance_id: balance_ids)
      .sum("amount_cents")
  end

  def loan_repayment_cents_for_balances(balance_ids)
    credits
      .where("financing_paydown_purchase_id IS NOT NULL OR json_data->>'$.stripe_loan_paydown_id' IS NOT NULL")
      .where(balance_id: balance_ids)
      .sum("amount_cents")
  end

  def fees_cents_for_balances(balance_ids)
    revenue_fees_cents = sales.where(purchase_success_balance_id: balance_ids).sum("fee_cents")
    revenue_fees_cents - returned_fees_due_to_refunds_and_chargebacks(balance_ids)
  end

  def returned_fees_due_to_refunds_and_chargebacks(balance_ids)
    refunded_sales = sales.is_refund_chargeback_fee_waived.where("purchase_refund_balance_id IN (?)", balance_ids)
    refunded_fee = refunded_sales.joins(:refunds).sum("refunds.fee_cents")
    refunded_sales_fee_not_waived = sales.not_is_refund_chargeback_fee_waived.where("purchase_refund_balance_id IN (?)", balance_ids)
    refunded_fee += refunded_sales_fee_not_waived.joins(:refunds).sum("refunds.fee_cents - COALESCE(refunds.json_data->'$.retained_fee_cents', 0)")
    disputed_sales = sales.where("purchase_chargeback_balance_id IN (?)", balance_ids)
    disputed_fee = disputed_sales.sum(:fee_cents) - disputed_sales.joins(:refunds).sum("refunds.fee_cents")
    refunded_fee + disputed_fee
  end

  def taxes_cents_for_balances(balance_ids)
    sales
      .successful
      .not_fully_refunded.not_chargedback_or_chargedback_reversed
      .where(purchase_success_balance_id: balance_ids)
      .sum("tax_cents")
  end

  def affiliate_credit_cents_for_balances(balance_ids)
    paid_scope = affiliate_credits.not_refunded_or_chargebacked.where(affiliate_credit_success_balance_id: balance_ids)
    refunded_cents = affiliate_credits
                         .where("affiliate_credit_refund_balance_id IN (?) OR affiliate_credit_chargeback_balance_id IN (?)",
                                balance_ids, balance_ids)
                         .where.not(affiliate_credit_success_balance_id: balance_ids).sum(:amount_cents)
    all_scope = affiliate_credits.where(affiliate_credit_success_balance_id: balance_ids)
    affiliate_credit_sum_from_scope(paid_scope, all_scope) - refunded_cents
  end

  def affiliate_fee_cents_for_balances(balance_ids)
    sales_scope = sales.where(purchase_success_balance_id: balance_ids)
    aff_fee_cents = sales_scope
                        .where("purchase_refund_balance_id IS NULL AND purchase_chargeback_balance_id IS NULL")
                        .sum("affiliate_credit_cents")
    aff_fee_cents += sales_scope
                         .where(stripe_partially_refunded: true)
                         .sum("affiliate_credit_cents")
    aff_fee_cents + returned_affiliate_fee_cents_due_to_refunds_and_chargebacks(balance_ids)
  end

  def returned_affiliate_fee_cents_due_to_refunds_and_chargebacks(balance_ids)
    sales_from_other_balances = sales.where.not(purchase_success_balance_id: balance_ids)

    refunded_sales = sales_from_other_balances.where(purchase_refund_balance_id: balance_ids)
    refunded_affiliate_fee_cents = BalanceTransaction.where(refund_id: Refund.where(purchase_id: refunded_sales.pluck(:id)))
                                     .where.not(user_id: id)
                                     .sum(:holding_amount_net_cents)

    disputed_sales = sales_from_other_balances.where(purchase_chargeback_balance_id: balance_ids)
    disputed_affiliate_fee_cents = BalanceTransaction.where(dispute_id: Dispute.where(purchase_id: disputed_sales.pluck(:id)))
                                     .where.not(user_id: id)
                                     .sum(:holding_amount_net_cents)

    refunded_affiliate_fee_cents + disputed_affiliate_fee_cents
  end

  def sales_data_for_balance_ids(balance_ids)
    {
      sales_cents: sales_cents_for_balances(balance_ids),
      refunds_cents: refunds_cents_for_balances(balance_ids),
      chargebacks_cents: chargebacks_cents_for_balances(balance_ids),
      credits_cents: credits_cents_for_balances(balance_ids),
      loan_repayment_cents: loan_repayment_cents_for_balances(balance_ids),
      fees_cents: fees_cents_for_balances(balance_ids),
      discover_fees_cents: discover_fees_cents_for_balances(balance_ids),
      direct_fees_cents: direct_fees_cents_for_balances(balance_ids),
      discover_sales_count: discover_sales_count_for_balances(balance_ids),
      direct_sales_count: direct_sales_count_for_balances(balance_ids),
      taxes_cents: taxes_cents_for_balances(balance_ids),
      affiliate_credits_cents: affiliate_credit_cents_for_balances(balance_ids),
      affiliate_fees_cents: affiliate_fee_cents_for_balances(balance_ids),
      paypal_payout_cents: 0
    }
  end

  def paypal_sales_in_duration(start_date:, end_date:)
    paypal_sales = sales.paypal.successful
    paypal_sales = paypal_sales.where("succeeded_at >= ?", start_date.beginning_of_day) if start_date
    paypal_sales = paypal_sales.where("succeeded_at <= ?", end_date.end_of_day) if end_date
    paypal_sales
  end

  def paypal_refunds_in_duration(start_date:, end_date:)
    paypal_refunds = Refund.joins(:purchase).where(
      seller_id: id,
      purchases: { charge_processor_id: PaypalChargeProcessor.charge_processor_id }
    )
    paypal_refunds = paypal_refunds.where("refunds.created_at >= ?", start_date.beginning_of_day) if start_date
    paypal_refunds = paypal_refunds.where("refunds.created_at <= ?", end_date.end_of_day) if end_date
    paypal_refunds
  end

  def paypal_sales_chargebacked_in_duration(start_date:, end_date:)
    disputed_paypal_sales = sales.paypal.chargedback.not_chargeback_reversed
    disputed_paypal_sales = disputed_paypal_sales.where("chargeback_date >= ?", start_date.beginning_of_day) if start_date
    disputed_paypal_sales = disputed_paypal_sales.where("chargeback_date <= ?", end_date.end_of_day) if end_date
    disputed_paypal_sales
  end

  def paypal_sales_cents_for_duration(start_date:, end_date:)
    paypal_sales_in_duration(start_date:, end_date:).sum(:price_cents)
  end

  def paypal_refunds_cents_for_duration(start_date:, end_date:)
    paypal_refunds_in_duration(start_date:, end_date:).sum(:amount_cents)
  end

  def paypal_chargebacked_cents_for_duration(start_date:, end_date:)
    paypal_sales_chargebacked_in_duration(start_date:, end_date:).sum(:price_cents)
  end

  def paypal_fees_cents_for_duration(start_date:, end_date:)
    revenue_fee_cents = paypal_sales_in_duration(start_date:, end_date:).sum(:fee_cents)
    revenue_fee_cents - paypal_returned_fees_due_to_refunds_and_chargebacks(start_date:, end_date:)
  end

  def paypal_returned_fees_due_to_refunds_and_chargebacks(start_date:, end_date:)
    refunded_fee = paypal_refunds_in_duration(start_date:, end_date:).sum(:fee_cents)
    disputed_fee = paypal_sales_chargebacked_in_duration(start_date:, end_date:).sum(:fee_cents)
    refunded_fee + disputed_fee
  end

  def paypal_discover_fees_cents_for_duration(start_date:, end_date:)
    revenue_fee_cents = paypal_sales_in_duration(start_date:, end_date:).was_discover_fee_charged.sum(:fee_cents)
    revenue_fee_cents - paypal_returned_discover_fees_due_to_refunds_and_chargebacks(start_date:, end_date:)
  end

  def paypal_returned_discover_fees_due_to_refunds_and_chargebacks(start_date:, end_date:)
    refunded_fee = paypal_refunds_in_duration(start_date:, end_date:)
                     .where("purchases.flags & ? > 0", Purchase.flag_mapping["flags"][:was_discover_fee_charged])
                     .sum(:fee_cents)
    disputed_fee = paypal_sales_chargebacked_in_duration(start_date:, end_date:).was_discover_fee_charged.sum(:fee_cents)
    refunded_fee + disputed_fee
  end

  def paypal_discover_sales_count_for_duration(start_date:, end_date:)
    paypal_sales_in_duration(start_date:, end_date:).was_discover_fee_charged.count
  end

  def paypal_direct_fees_cents_for_duration(start_date:, end_date:)
    revenue_fee_cents = paypal_sales_in_duration(start_date:, end_date:).not_was_discover_fee_charged.sum(:fee_cents)
    revenue_fee_cents - paypal_returned_direct_fees_due_to_refunds_and_chargebacks(start_date:, end_date:)
  end

  def paypal_returned_direct_fees_due_to_refunds_and_chargebacks(start_date:, end_date:)
    refunded_fee = paypal_refunds_in_duration(start_date:, end_date:)
                     .where("purchases.flags & ? = 0", Purchase.flag_mapping["flags"][:was_discover_fee_charged])
                     .sum(:fee_cents)
    disputed_fee = paypal_sales_chargebacked_in_duration(start_date:, end_date:).not_was_discover_fee_charged.sum(:fee_cents)
    refunded_fee + disputed_fee
  end

  def paypal_direct_sales_count_for_duration(start_date:, end_date:)
    paypal_sales_in_duration(start_date:, end_date:).not_was_discover_fee_charged.count
  end

  def paypal_taxes_cents_for_duration(start_date:, end_date:)
    tax_cents = paypal_sales_in_duration(start_date:, end_date:).sum(:tax_cents)
    tax_cents - paypal_returned_taxes_due_to_refunds_and_chargebacks(start_date:, end_date:)
  end

  def paypal_returned_taxes_due_to_refunds_and_chargebacks(start_date:, end_date:)
    refunded_tax = paypal_refunds_in_duration(start_date:, end_date:).sum(:tax_cents)
    disputed_tax = paypal_sales_chargebacked_in_duration(start_date:, end_date:).sum(:tax_cents)
    refunded_tax + disputed_tax
  end

  def paypal_affiliate_fee_cents_for_duration(start_date:, end_date:)
    aff_fee_cents = paypal_sales_in_duration(start_date:, end_date:).sum("affiliate_credit_cents")
    aff_fee_cents - paypal_returned_affiliate_fee_cents_due_to_refunds_and_chargebacks(start_date:, end_date:)
  end

  def paypal_returned_affiliate_fee_cents_due_to_refunds_and_chargebacks(start_date:, end_date:)
    refunded_affiliate_fee_cents = paypal_refunds_in_duration(start_date:, end_date:)
                                       .sum("purchases.affiliate_credit_cents * (refunds.amount_cents / purchases.price_cents)").round

    disputed_affiliate_fee_cents = paypal_sales_chargebacked_in_duration(start_date:, end_date:).sum(:affiliate_credit_cents)

    refunded_affiliate_fee_cents + disputed_affiliate_fee_cents
  end

  def paypal_sales_data_for_duration(start_date:, end_date:)
    {
      sales_cents: paypal_sales_cents_for_duration(start_date:, end_date:),
      refunds_cents: paypal_refunds_cents_for_duration(start_date:, end_date:),
      chargebacks_cents: paypal_chargebacked_cents_for_duration(start_date:, end_date:),
      credits_cents: 0,
      fees_cents: paypal_fees_cents_for_duration(start_date:, end_date:),
      discover_fees_cents: paypal_discover_fees_cents_for_duration(start_date:, end_date:),
      direct_fees_cents: paypal_direct_fees_cents_for_duration(start_date:, end_date:),
      discover_sales_count: paypal_discover_sales_count_for_duration(start_date:, end_date:),
      direct_sales_count: paypal_direct_sales_count_for_duration(start_date:, end_date:),
      taxes_cents: paypal_taxes_cents_for_duration(start_date:, end_date:),
      affiliate_credits_cents: 0,
      affiliate_fees_cents: paypal_affiliate_fee_cents_for_duration(start_date:, end_date:),
    }
  end

  def paypal_payout_net_cents(paypal_sales_data)
    paypal_sales_data[:sales_cents] -
        paypal_sales_data[:refunds_cents] -
        paypal_sales_data[:chargebacks_cents] -
        paypal_sales_data[:fees_cents] -
        paypal_sales_data[:affiliate_fees_cents]
  end

  # Similar to Payment::Stats#revenue_by_link
  def paypal_revenue_by_product_for_duration(start_date:, end_date:)
    revenue_by_product = paypal_sales_in_duration(start_date:, end_date:)
                          .group("link_id")
                          .sum("price_cents - fee_cents - affiliate_credit_cents")
    revenue_by_product.default = 0

    chargedback_amounts = paypal_sales_chargebacked_in_duration(start_date:, end_date:)
                              .group(:link_id)
                              .sum("price_cents - fee_cents - affiliate_credit_cents")
    chargedback_amounts.each { |product, chargeback_amount| revenue_by_product[product] -= chargeback_amount }

    refunded_amounts = paypal_refunds_in_duration(start_date:, end_date:)
                         .group(:link_id)
                         .sum("refunds.amount_cents - refunds.fee_cents - TRUNCATE(purchases.affiliate_credit_cents * (refunds.amount_cents / purchases.price_cents), 0)")
    refunded_amounts.each { |product, refund_amount| revenue_by_product[product] -= refund_amount }

    revenue_by_product
  end

  def stripe_connect_sales_in_duration(start_date:, end_date:)
    stripe_connect_sales = sales.stripe.successful.
      where(merchant_account_id: merchant_accounts.filter_map { |ma| ma.id if ma.is_a_stripe_connect_account? })
    stripe_connect_sales = stripe_connect_sales.where("succeeded_at >= ?", start_date.beginning_of_day) if start_date
    stripe_connect_sales = stripe_connect_sales.where("succeeded_at <= ?", end_date.end_of_day) if end_date
    stripe_connect_sales
  end

  def stripe_connect_refunds_in_duration(start_date:, end_date:)
    stripe_connect_refunds = Refund.joins(:purchase).where(
      seller_id: id,
      purchases: {
        charge_processor_id: StripeChargeProcessor.charge_processor_id,
        merchant_account_id: merchant_accounts.filter_map { |ma| ma.id if ma.is_a_stripe_connect_account? }
      }
    )
    stripe_connect_refunds = stripe_connect_refunds.where("refunds.created_at >= ?", start_date.beginning_of_day) if start_date
    stripe_connect_refunds = stripe_connect_refunds.where("refunds.created_at <= ?", end_date.end_of_day) if end_date
    stripe_connect_refunds
  end

  def stripe_connect_sales_chargebacked_in_duration(start_date:, end_date:)
    disputed_stripe_connect_sales =
      sales.stripe
           .where(merchant_account_id: merchant_accounts.filter_map { |ma| ma.id if ma.is_a_stripe_connect_account? })
           .chargedback.not_chargeback_reversed
    disputed_stripe_connect_sales = disputed_stripe_connect_sales.where("chargeback_date >= ?", start_date.beginning_of_day) if start_date
    disputed_stripe_connect_sales = disputed_stripe_connect_sales.where("chargeback_date <= ?", end_date.end_of_day) if end_date
    disputed_stripe_connect_sales
  end

  def stripe_connect_sales_cents_for_duration(start_date:, end_date:)
    stripe_connect_sales_in_duration(start_date:, end_date:).sum(:price_cents)
  end

  def stripe_connect_refunds_cents_for_duration(start_date:, end_date:)
    stripe_connect_refunds_in_duration(start_date:, end_date:).sum(:amount_cents)
  end

  def stripe_connect_chargebacked_cents_for_duration(start_date:, end_date:)
    stripe_connect_sales_chargebacked_in_duration(start_date:, end_date:).sum(:price_cents)
  end

  def stripe_connect_fees_cents_for_duration(start_date:, end_date:)
    revenue_fee_cents = stripe_connect_sales_in_duration(start_date:, end_date:).sum(:fee_cents)
    revenue_fee_cents - stripe_connect_returned_fees_due_to_refunds_and_chargebacks(start_date:, end_date:)
  end

  def stripe_connect_returned_fees_due_to_refunds_and_chargebacks(start_date:, end_date:)
    refunded_fee = stripe_connect_refunds_in_duration(start_date:, end_date:).sum(:fee_cents)
    disputed_fee = stripe_connect_sales_chargebacked_in_duration(start_date:, end_date:).sum(:fee_cents)
    refunded_fee + disputed_fee
  end

  def stripe_connect_discover_fees_cents_for_duration(start_date:, end_date:)
    revenue_fee_cents = stripe_connect_sales_in_duration(start_date:, end_date:).was_discover_fee_charged.sum(:fee_cents)
    revenue_fee_cents - stripe_connect_returned_discover_fees_due_to_refunds_and_chargebacks(start_date:, end_date:)
  end

  def stripe_connect_returned_discover_fees_due_to_refunds_and_chargebacks(start_date:, end_date:)
    refunded_fee = stripe_connect_refunds_in_duration(start_date:, end_date:)
                     .where("purchases.flags & ? > 0", Purchase.flag_mapping["flags"][:was_discover_fee_charged])
                     .sum(:fee_cents)
    disputed_fee = stripe_connect_sales_chargebacked_in_duration(start_date:, end_date:).was_discover_fee_charged.sum(:fee_cents)
    refunded_fee + disputed_fee
  end

  def stripe_connect_discover_sales_count_for_duration(start_date:, end_date:)
    stripe_connect_sales_in_duration(start_date:, end_date:).was_discover_fee_charged.count
  end

  def stripe_connect_direct_fees_cents_for_duration(start_date:, end_date:)
    revenue_fee_cents = stripe_connect_sales_in_duration(start_date:, end_date:).not_was_discover_fee_charged.sum(:fee_cents)
    revenue_fee_cents - stripe_connect_returned_direct_fees_due_to_refunds_and_chargebacks(start_date:, end_date:)
  end

  def stripe_connect_returned_direct_fees_due_to_refunds_and_chargebacks(start_date:, end_date:)
    refunded_fee = stripe_connect_refunds_in_duration(start_date:, end_date:)
                     .where("purchases.flags & ? = 0", Purchase.flag_mapping["flags"][:was_discover_fee_charged])
                     .sum(:fee_cents)
    disputed_fee = stripe_connect_sales_chargebacked_in_duration(start_date:, end_date:).not_was_discover_fee_charged.sum(:fee_cents)
    refunded_fee + disputed_fee
  end

  def stripe_connect_direct_sales_count_for_duration(start_date:, end_date:)
    stripe_connect_sales_in_duration(start_date:, end_date:).not_was_discover_fee_charged.count
  end

  def stripe_connect_taxes_cents_for_duration(start_date:, end_date:)
    tax_cents = stripe_connect_sales_in_duration(start_date:, end_date:).sum(:tax_cents)
    tax_cents - stripe_connect_returned_taxes_due_to_refunds_and_chargebacks(start_date:, end_date:)
  end

  def stripe_connect_returned_taxes_due_to_refunds_and_chargebacks(start_date:, end_date:)
    refunded_tax = stripe_connect_refunds_in_duration(start_date:, end_date:).sum(:tax_cents)
    disputed_tax = stripe_connect_sales_chargebacked_in_duration(start_date:, end_date:).sum(:tax_cents)
    refunded_tax + disputed_tax
  end

  def stripe_connect_affiliate_fee_cents_for_duration(start_date:, end_date:)
    aff_fee_cents = stripe_connect_sales_in_duration(start_date:, end_date:).sum("affiliate_credit_cents")
    aff_fee_cents - stripe_connect_returned_affiliate_fee_cents_due_to_refunds_and_chargebacks(start_date:, end_date:)
  end

  def stripe_connect_returned_affiliate_fee_cents_due_to_refunds_and_chargebacks(start_date:, end_date:)
    refunded_affiliate_fee_cents = stripe_connect_refunds_in_duration(start_date:, end_date:)
                                     .sum("purchases.affiliate_credit_cents * (refunds.amount_cents / purchases.price_cents)").round

    disputed_affiliate_fee_cents = stripe_connect_sales_chargebacked_in_duration(start_date:, end_date:).sum(:affiliate_credit_cents)

    refunded_affiliate_fee_cents + disputed_affiliate_fee_cents
  end

  def stripe_connect_sales_data_for_duration(start_date:, end_date:)
    {
      sales_cents: stripe_connect_sales_cents_for_duration(start_date:, end_date:),
      refunds_cents: stripe_connect_refunds_cents_for_duration(start_date:, end_date:),
      chargebacks_cents: stripe_connect_chargebacked_cents_for_duration(start_date:, end_date:),
      credits_cents: 0,
      fees_cents: stripe_connect_fees_cents_for_duration(start_date:, end_date:),
      discover_fees_cents: stripe_connect_discover_fees_cents_for_duration(start_date:, end_date:),
      direct_fees_cents: stripe_connect_direct_fees_cents_for_duration(start_date:, end_date:),
      discover_sales_count: stripe_connect_discover_sales_count_for_duration(start_date:, end_date:),
      direct_sales_count: stripe_connect_direct_sales_count_for_duration(start_date:, end_date:),
      taxes_cents: stripe_connect_taxes_cents_for_duration(start_date:, end_date:),
      affiliate_credits_cents: 0,
      affiliate_fees_cents: stripe_connect_affiliate_fee_cents_for_duration(start_date:, end_date:),
    }
  end

  def stripe_connect_payout_net_cents(stripe_connect_sales_data)
    stripe_connect_sales_data[:sales_cents] -
        stripe_connect_sales_data[:refunds_cents] -
        stripe_connect_sales_data[:chargebacks_cents] -
        stripe_connect_sales_data[:fees_cents] -
        stripe_connect_sales_data[:affiliate_fees_cents]
  end

  # Similar to Payment::Stats#revenue_by_link
  def stripe_connect_revenue_by_product_for_duration(start_date:, end_date:)
    revenue_by_product = stripe_connect_sales_in_duration(start_date:, end_date:)
                             .group("link_id")
                             .sum("price_cents - fee_cents - affiliate_credit_cents")
    revenue_by_product.default = 0

    chargedback_amounts = stripe_connect_sales_chargebacked_in_duration(start_date:, end_date:)
                              .group(:link_id)
                              .sum("price_cents - fee_cents - affiliate_credit_cents")
    chargedback_amounts.each { |product, chargeback_amount| revenue_by_product[product] -= chargeback_amount }

    refunded_amounts = stripe_connect_refunds_in_duration(start_date:, end_date:)
                         .group(:link_id)
                         .sum("refunds.amount_cents - refunds.fee_cents - TRUNCATE(purchases.affiliate_credit_cents * (refunds.amount_cents / purchases.price_cents), 0)")
    refunded_amounts.each { |product, refund_amount| revenue_by_product[product] -= refund_amount }

    revenue_by_product
  end

  def active?(number_of_days)
    sales_in_time_period = sales.successful.where("created_at > ?", number_of_days.days.ago).count
    new_links_in_time_period = links.where("created_at > ?", number_of_days.days.ago).count
    (sales_in_time_period + new_links_in_time_period) > 0
  end

  def product_count
    links.visible.count
  end

  def total_amount_made_cents
    balances.sum(:amount_cents)
  end

  # Public: Returns the list of products that should be considered for creator analytics purposes.
  # We omit products only if they've been deleted or archived *and* they don't have any sales.
  def products_for_creator_analytics
    successful_purchase_exists_sql = Purchase.successful_or_preorder_authorization_successful.where("purchases.link_id = links.id").to_sql
    links.where("EXISTS (#{successful_purchase_exists_sql}) OR (links.deleted_at IS NULL AND #{Link.not_archived_condition})")
         .order(id: :desc)
  end

  def first_sale_created_at_for_analytics
    union_sql = [:successful, :preorder_authorization_successful, :preorder_concluded_successfully].map do |state|
      "(" + sales.order(:created_at).select(:created_at).limit(1).where(purchase_state: state).to_sql + ")"
    end.join(" UNION ")
    sql = "SELECT created_at FROM (#{union_sql}) subquery ORDER BY created_at ASC LIMIT 1"
    ApplicationRecord.connection.execute(sql).to_a.flatten.first
  end

  def archived_products_count
    links.visible.archived.count
  end

  def all_sales_count
    total = PurchaseSearchService.search(
      seller: self,
      state: Purchase::NON_GIFT_SUCCESS_STATES,
      exclude_giftees: true,
      exclude_refunded_except_subscriptions: true,
      exclude_unreversed_chargedback: true,
      exclude_non_original_subscription_purchases: true,
      exclude_commission_completion_purchases: true,
      exclude_bundle_product_purchases: true,
      size: 0,
      track_total_hits: true,
    ).results.total
    total + imported_customers.alive.count
  end

  def distinct_paid_customers_count_last_year
    # Note: This logic was imported from the deprecated User#customers method.
    # https://github.com/gumroad/web/blob/06bbac3499e82a198b7bd17b26e0ccbcf2939cf8/app/modules/user/customers.rb#L20-L55
    matching_sales = sales.all_success_states.not_is_gift_receiver_purchase
    subscription_product_ids = links.visible.is_recurring_billing.pluck(:id)

    unless subscription_product_ids.empty?
      subscriptions = Subscription.active.not_is_test_subscription.where(link_id: subscription_product_ids).select(:id)
      matching_sales = matching_sales.where(
        "purchases.subscription_id IS NULL OR (purchases.flags & ? != 0 AND purchases.subscription_id IN (?))",
        Purchase.flag_mapping["flags"][:is_original_subscription_purchase],
        subscriptions
      )
    end

    matching_sales.where("created_at > ? and price_cents > 0", 1.year.ago).select(:email).distinct.count
  end

  def active_members_count
    product_ids = products.membership.visible.ids
    Link.successful_sales_count(products: product_ids)
  end

  def monthly_recurring_revenue
    product_ids = products.membership.visible.ids
    Link.monthly_recurring_revenue(products: product_ids)
  end

  def discover_fees_cents_for_balances(balance_ids)
    revenue_fees_cents = sales.where(purchase_success_balance_id: balance_ids).was_discover_fee_charged.sum("fee_cents")
    revenue_fees_cents - returned_discover_fees_due_to_refunds_and_chargebacks(balance_ids)
  end

  def returned_discover_fees_due_to_refunds_and_chargebacks(balance_ids)
    refunded_sales = sales.was_discover_fee_charged.is_refund_chargeback_fee_waived.where("purchase_refund_balance_id IN (?)", balance_ids)
    refunded_fee = refunded_sales.joins(:refunds).sum("refunds.fee_cents")
    refunded_sales_fee_not_waived = sales.was_discover_fee_charged.not_is_refund_chargeback_fee_waived.where("purchase_refund_balance_id IN (?)", balance_ids)
    refunded_fee += refunded_sales_fee_not_waived.joins(:refunds).sum("refunds.fee_cents - COALESCE(refunds.json_data->'$.retained_fee_cents', 0)")
    disputed_sales = sales.was_discover_fee_charged.where("purchase_chargeback_balance_id IN (?)", balance_ids)
    disputed_fee = disputed_sales.sum(:fee_cents) - disputed_sales.joins(:refunds).sum("refunds.fee_cents")
    refunded_fee + disputed_fee
  end

  def direct_fees_cents_for_balances(balance_ids)
    revenue_fees_cents = sales.where(purchase_success_balance_id: balance_ids).not_was_discover_fee_charged.sum("fee_cents")
    revenue_fees_cents - returned_direct_fees_due_to_refunds_and_chargebacks(balance_ids)
  end

  def returned_direct_fees_due_to_refunds_and_chargebacks(balance_ids)
    refunded_sales = sales.not_was_discover_fee_charged.is_refund_chargeback_fee_waived.where("purchase_refund_balance_id IN (?)", balance_ids)
    refunded_fee = refunded_sales.joins(:refunds).sum("refunds.fee_cents")
    refunded_sales_fee_not_waived = sales.not_was_discover_fee_charged.not_is_refund_chargeback_fee_waived.where("purchase_refund_balance_id IN (?)", balance_ids)
    refunded_fee += refunded_sales_fee_not_waived.joins(:refunds).sum("refunds.fee_cents - COALESCE(refunds.json_data->'$.retained_fee_cents', 0)")
    disputed_sales = sales.not_was_discover_fee_charged.where("purchase_chargeback_balance_id IN (?)", balance_ids)
    disputed_fee = disputed_sales.sum(:fee_cents) - disputed_sales.joins(:refunds).sum("refunds.fee_cents")
    refunded_fee + disputed_fee
  end

  def discover_sales_count_for_balances(balance_ids)
    sales.where(purchase_success_balance_id: balance_ids).was_discover_fee_charged.count
  end

  def direct_sales_count_for_balances(balance_ids)
    sales.where(purchase_success_balance_id: balance_ids).not_was_discover_fee_charged.count
  end

  private
    def revenue_as_seller(after: nil)
      search_params = {
        seller: self,
        price_greater_than: 0,
        state: "successful",
        exclude_unreversed_chargedback: true,
        exclude_refunded: true,
        exclude_bundle_product_purchases: true,
        created_after: after,
        size: 0,
        aggs: {
          price_cents_total: { sum: { field: "price_cents" } },
          fee_cents_total: { sum: { field: "fee_cents" } },
          amount_refunded_cents_total: { sum: { field: "amount_refunded_cents" } },
          fee_refunded_cents_total: { sum: { field: "fee_refunded_cents" } },
          affiliate_credit_amount_cents_total: { sum: { field: "affiliate_credit_amount_cents" } },
          affiliate_credit_amount_partially_refunded_cents_total: { sum: { field: "affiliate_credit_amount_partially_refunded_cents" } }
        }
      }

      total = 0
      result = PurchaseSearchService.search(search_params)
      total += result.aggregations.price_cents_total.value
      total -= result.aggregations.fee_cents_total.value
      total -= result.aggregations.amount_refunded_cents_total.value
      total += result.aggregations.fee_refunded_cents_total.value
      total -= result.aggregations.affiliate_credit_amount_cents_total.value
      total += result.aggregations.affiliate_credit_amount_partially_refunded_cents_total.value
      total.to_i
    end

    def revenue_as_affiliate(after: nil)
      search_params = {
        affiliate_user: self,
        price_greater_than: 0,
        state: "successful",
        exclude_unreversed_chargedback: true,
        exclude_refunded: true,
        exclude_bundle_product_purchases: true,
        created_after: after,
        size: 0,
        aggs: {
          affiliate_credit_amount_cents_total: { sum: { field: "affiliate_credit_amount_cents" } },
          affiliate_credit_amount_partially_refunded_cents_total: { sum: { field: "affiliate_credit_amount_partially_refunded_cents" } }
        }
      }

      result = PurchaseSearchService.search(search_params)
      total = 0
      total += result.aggregations.affiliate_credit_amount_cents_total.value
      total -= result.aggregations.affiliate_credit_amount_partially_refunded_cents_total.value
      total.to_i
    end

    def page_basis_points_floor(page_number:, total_page_count:)
      (page_number / total_page_count.to_f * 10_000).floor
    end

    def page_basis_points_ceil(page_number:, total_page_count:)
      (page_number / total_page_count.to_f * 10_000).ceil
    end
end
