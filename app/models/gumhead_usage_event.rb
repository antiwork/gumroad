# frozen_string_literal: true

# One row per model call the Gumhead gateway forwarded for a user — the
# ledger behind the gateway's daily token caps and cost reporting. Rows are
# written after the upstream call returns, so the caps are enforced against
# what was already spent, not against what a request might spend.
class GumheadUsageEvent < ApplicationRecord
  belongs_to :user

  validates :model, presence: true
  # The caps sum these columns; a negative row would silently raise every
  # later request's remaining budget.
  validates :input_tokens, :output_tokens, :cache_creation_input_tokens,
            :cache_creation_1h_input_tokens, :cache_read_input_tokens,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # Cache tokens are billed too, so the input cap counts a cost-weighted
  # total — otherwise a cache-heavy agent loop would spend almost entirely
  # outside the cap. Defaults follow Grok 4.6 ($2 input / $0.50 cache
  # read, no write premium). Anthropic's 1.25 / 2 / 0.1 stay available
  # via GlobalConfig if the upstream moves back.
  # `cache_creation_input_tokens` is the total across both TTLs, so the
  # 1-hour share is stored separately and re-weighted here.
  CACHE_CREATION_COST_MULTIPLIER = 1.0
  CACHE_CREATION_1H_COST_MULTIPLIER = 1.0
  CACHE_READ_COST_MULTIPLIER = 0.25

  def self.input_equivalent_tokens_today(user)
    creation = cache_cost_multiplier("GUMHEAD_CACHE_CREATION_COST_MULTIPLIER", CACHE_CREATION_COST_MULTIPLIER)
    creation_1h = cache_cost_multiplier("GUMHEAD_CACHE_CREATION_1H_COST_MULTIPLIER", CACHE_CREATION_1H_COST_MULTIPLIER)
    read = cache_cost_multiplier("GUMHEAD_CACHE_READ_COST_MULTIPLIER", CACHE_READ_COST_MULTIPLIER)
    where(user:, created_at: Time.current.all_day)
      .sum(
        "input_tokens + " \
        "CEIL((cache_creation_input_tokens - cache_creation_1h_input_tokens) * #{creation}) + " \
        "(cache_creation_1h_input_tokens * #{creation_1h}) + " \
        "CEIL(cache_read_input_tokens * #{read})"
      ).to_i
  end

  def self.cache_cost_multiplier(name, default)
    value = Float(GlobalConfig.get(name, default))
    raise ArgumentError, "#{name} must be a finite number" unless value.finite?
    value
  end
  private_class_method :cache_cost_multiplier

  def self.output_tokens_today(user)
    where(user:, created_at: Time.current.all_day).sum(:output_tokens)
  end
end
