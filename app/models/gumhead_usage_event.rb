# frozen_string_literal: true

# One row per model call the Gumhead gateway forwarded for a user — the
# ledger behind the gateway's daily token caps and cost reporting. Rows are
# written after the upstream call returns, so the caps are enforced against
# what was already spent, not against what a request might spend.
class GumheadUsageEvent < ApplicationRecord
  belongs_to :user

  validates :model, presence: true

  def self.input_tokens_today(user)
    where(user:, created_at: Time.current.all_day).sum(:input_tokens)
  end

  def self.output_tokens_today(user)
    where(user:, created_at: Time.current.all_day).sum(:output_tokens)
  end
end
