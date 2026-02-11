# frozen_string_literal: true

module User::Taxation
  extend ActiveSupport::Concern
  include Compliance

  MIN_SALE_AMOUNT_FOR_1099_K_FEDERAL_FILING = 20_000 * 100
  MIN_SALE_COUNT_FOR_1099_K_FEDERAL_FILING = 200
  MIN_SALE_AMOUNT_FOR_1099_K_FEDERAL_FILING_FOR_YEAR = { 2024 => 5_000 }
  MIN_SALE_COUNT_FOR_1099_K_FEDERAL_FILING_FOR_YEAR = { 2024 => 0 }

  # Ref https://docs.stripe.com/connect/1099-K for state filing thresholds
  MIN_SALE_AMOUNTS_FOR_1099_K_STATE_FILINGS = {
    "AL" => MIN_SALE_AMOUNT_FOR_1099_K_FEDERAL_FILING, # Alabama
    "AR" => 2_500 * 100,                               # Arkansas
    "CA" => MIN_SALE_AMOUNT_FOR_1099_K_FEDERAL_FILING, # California
    "DC" => 600 * 100,                                 # District of Columbia
    "FL" => MIN_SALE_AMOUNT_FOR_1099_K_FEDERAL_FILING, # Florida
    "GA" => MIN_SALE_AMOUNT_FOR_1099_K_FEDERAL_FILING, # Georgia
    "HI" => MIN_SALE_AMOUNT_FOR_1099_K_FEDERAL_FILING, # Hawaii
    "IL" => 1_000 * 100,                               # Illinois
    "ME" => MIN_SALE_AMOUNT_FOR_1099_K_FEDERAL_FILING, # Maine
    "MA" => 600 * 100,                                 # Massachusetts
    "MT" => 600 * 100,                                 # Montana
    "NJ" => 1_000 * 100,                               # New Jersey
    "NY" => MIN_SALE_AMOUNT_FOR_1099_K_FEDERAL_FILING, # New York
    "OR" => MIN_SALE_AMOUNT_FOR_1099_K_FEDERAL_FILING, # Oregon
    "TN" => MIN_SALE_AMOUNT_FOR_1099_K_FEDERAL_FILING, # Tennessee
    "VA" => 600 * 100,                                 # Virginia
  }

  MIN_AFFILIATE_AMOUNT_FOR_1099_MISC_FEDERAL_FILING = 600 * 100
  # Ref https://docs.stripe.com/connect/1099-MISC for state filing thresholds
  MIN_AFFILIATE_AMOUNTS_FOR_1099_MISC_STATE_FILINGS = {
    "AR" => 2_500 * 100,                                       # Arkansas
    "CA" => MIN_AFFILIATE_AMOUNT_FOR_1099_MISC_FEDERAL_FILING, # California
    "DC" => MIN_AFFILIATE_AMOUNT_FOR_1099_MISC_FEDERAL_FILING, # District of Columbia
    "HI" => MIN_AFFILIATE_AMOUNT_FOR_1099_MISC_FEDERAL_FILING, # Hawaii
    "ME" => MIN_AFFILIATE_AMOUNT_FOR_1099_MISC_FEDERAL_FILING, # Maine
    "MA" => MIN_AFFILIATE_AMOUNT_FOR_1099_MISC_FEDERAL_FILING, # Massachusetts
    "MT" => MIN_AFFILIATE_AMOUNT_FOR_1099_MISC_FEDERAL_FILING, # Montana
    "NJ" => MIN_AFFILIATE_AMOUNT_FOR_1099_MISC_FEDERAL_FILING, # New Jersey
    "OR" => MIN_AFFILIATE_AMOUNT_FOR_1099_MISC_FEDERAL_FILING, # Oregon
  }

  def eligible_for_1099_k?(year)
    return false unless is_a_non_suspended_creator_from_usa?
    return false unless eligible_for_1099_k_federal_filing?(year) || eligible_for_1099_k_state_filing?(year)

    true
  end

  def eligible_for_1099_k_federal_filing?(year)
    min_sale_amount_for_1099_k_federal_filing = MIN_SALE_AMOUNT_FOR_1099_K_FEDERAL_FILING_FOR_YEAR[year] || MIN_SALE_AMOUNT_FOR_1099_K_FEDERAL_FILING
    min_sale_count_for_1099_k_federal_filing = MIN_SALE_COUNT_FOR_1099_K_FEDERAL_FILING_FOR_YEAR[year] || MIN_SALE_COUNT_FOR_1099_K_FEDERAL_FILING

    sales_scope_for(year).sum(:total_transaction_cents) >= min_sale_amount_for_1099_k_federal_filing &&
      sales_scope_for(year).count >= min_sale_count_for_1099_k_federal_filing
  end

  def eligible_for_1099_k_state_filing?(year)
    state = alive_user_compliance_info.legal_entity_state
    return false unless MIN_SALE_AMOUNTS_FOR_1099_K_STATE_FILINGS.key?(state)
    return false unless sales_scope_for(year).sum(:total_transaction_cents) >= MIN_SALE_AMOUNTS_FOR_1099_K_STATE_FILINGS[state]

    true
  end

  def eligible_for_1099_misc?(year)
    return false unless is_a_non_suspended_creator_from_usa?
    return false unless eligible_for_1099_misc_federal_filing?(year) || eligible_for_1099_misc_state_filing?(year)

    true
  end

  def eligible_for_1099_misc_federal_filing?(year)
    affiliate_sales_scope_for(year).sum(:affiliate_credit_cents) >= MIN_AFFILIATE_AMOUNT_FOR_1099_MISC_FEDERAL_FILING
  end

  def eligible_for_1099_misc_state_filing?(year)
    state = alive_user_compliance_info.legal_entity_state
    return false unless MIN_AFFILIATE_AMOUNTS_FOR_1099_MISC_STATE_FILINGS.key?(state)
    return false unless affiliate_sales_scope_for(year).sum(:affiliate_credit_cents) >= MIN_AFFILIATE_AMOUNTS_FOR_1099_MISC_STATE_FILINGS[state]

    true
  end

  def eligible_for_1099?(year)
    return false unless is_a_non_suspended_creator_from_usa?

    eligible_for_1099_k?(year) || eligible_for_1099_misc?(year)
  end

  def is_a_non_suspended_creator_from_usa?
    return false if suspended?
    return false unless from_us?

    true
  end

  def from_us?
    alive_user_compliance_info&.country_code == Compliance::Countries::USA.alpha2
  end

  private
    def sales_scope_for(year)
      range = Date.new(year).in_time_zone(timezone).all_year
      sales.successful.not_fully_refunded.not_chargedback_or_chargedback_reversed
           .where("purchases.price_cents > 0")
           .where(paypal_order_id: nil)
           .where.not(merchant_account_id: merchant_accounts.select { _1.is_a_stripe_connect_account? }.map(&:id))
           .where(created_at: range)
    end

    def affiliate_sales_scope_for(year)
      range = Date.new(year).in_time_zone(timezone).all_year
      affiliate_sales.successful.not_fully_refunded.not_chargedback_or_chargedback_reversed.where(created_at: range)
    end
end
