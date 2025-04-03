# frozen_string_literal: true

module User::Tier
  # Earning tiers
  TIER_0 = 0
  TIER_1 = 1_000
  TIER_2 = 10_000
  TIER_3 = 100_000
  TIER_4 = 1_000_000

  TIER_RANGES = {
    0...1_000_00 => TIER_0,
    1_000_00...10_000_00 => TIER_1,
    10_000_00...100_000_00 => TIER_2,
    100_000_00...1_000_000_00 => TIER_3,
    1_000_000_00...Float::INFINITY => TIER_4,
  }.freeze

  TIER_FEES_MERCHANT_ACCOUNT = {
    TIER_0 => 0.09,
    TIER_1 => 0.07,
    TIER_2 => 0.05,
    TIER_3 => 0.03,
    TIER_4 => 0.029,
  }

  TIER_FEES_NON_MERCHANT_ACCOUNT = {
    TIER_0 => 0.07,
    TIER_1 => 0.05,
    TIER_2 => 0.03,
    TIER_3 => 0.01,
    TIER_4 => 0.009,
  }

  def tier(sales_cents = nil)
    return unless tier_pricing_enabled?

    return TIER_0 if sales_cents && sales_cents <= 0

    sales_cents ? TIER_RANGES.select { |range| range === sales_cents }.values.first : tier_state
  end

  def tier_fee(is_merchant_account: nil)
    return unless tier_pricing_enabled?

    is_merchant_account ? TIER_FEES_MERCHANT_ACCOUNT[tier] : TIER_FEES_NON_MERCHANT_ACCOUNT[tier]
  end

  def formatted_tier_earning(sales_cents: nil)
    return unless tier_pricing_enabled?

    Money.new(tier(sales_cents) * 100, :usd).format(with_currency: false, no_cents_if_whole: true)
  end

  def formatted_tier_fee_percentage(is_merchant_account: nil)
    return unless tier_pricing_enabled?

    (tier_fee(is_merchant_account:) * 100).round(1)
  end

  def tier_pricing_enabled?
    true
  end

  def log_tier_transition(from_tier:, to_tier:)
    logger.info "User: user ID #{id} transitioned from tier #{from_tier} to tier #{to_tier}"
  end
end
