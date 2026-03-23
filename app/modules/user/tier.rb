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

  def tier(sales_cents = nil)
    return TIER_0 if sales_cents && sales_cents <= 0

    sales_cents ? TIER_RANGES.select { |range| range === sales_cents }.values.first : tier_state
  end

  def log_tier_transition(from_tier:, to_tier:)
    logger.info "User: user ID #{id} transitioned from tier #{from_tier} to tier #{to_tier}"
  end
end
