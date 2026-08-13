# frozen_string_literal: true

# One row per model call the Gumhead gateway forwarded for a user — the
# ledger behind the gateway's daily token caps and cost reporting. Rows are
# written after the upstream call returns, so the caps are enforced against
# what was already spent, not against what a request might spend.
class GumheadUsageEvent < ApplicationRecord
  belongs_to :user

  validates :model, presence: true

  # Cache tokens are billed too (creation at a premium, reads at a
  # discount), so the input cap counts a cost-weighted total — otherwise a
  # cache-heavy agent loop would spend almost entirely outside the cap.
  CACHE_CREATION_COST_MULTIPLIER = 1.25
  CACHE_READ_COST_MULTIPLIER = 0.1

  def self.input_equivalent_tokens_today(user)
    where(user:, created_at: Time.current.all_day)
      .sum(
        "input_tokens + CEIL(cache_creation_input_tokens * #{CACHE_CREATION_COST_MULTIPLIER}) + " \
        "CEIL(cache_read_input_tokens * #{CACHE_READ_COST_MULTIPLIER})"
      ).to_i
  end

  def self.output_tokens_today(user)
    where(user:, created_at: Time.current.all_day).sum(:output_tokens)
  end
end
