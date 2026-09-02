# frozen_string_literal: true

# One row per held seller per scan day: what the social-connect score was and
# whether it WOULD have auto-released the hold. Read-only evidence for tuning
# thresholds (gumroad-private#2371 slice 2) — nothing consumes these rows to
# move money.
class SocialScoreShadowEvaluation < ApplicationRecord
  belongs_to :user

  validates :evaluated_on, presence: true, uniqueness: { scope: :user_id }
  validates :hold_source, presence: true
  validates :score, presence: true
  validates :unpaid_balance_cents, presence: true
end
