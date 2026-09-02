# frozen_string_literal: true

# Shadow-mode scorer for payout-hold risk reviews (gumroad-private#2371, slice 2).
# Computes, for a seller whose payout is currently held, whether verified
# social-connect signals WOULD have released the hold — and only logs the
# verdict. Nothing here moves money or clears a hold; the release path stays
# manual until measured precision says otherwise.
class SocialScoreShadowEvaluationService
  # Chosen so that no single signal can release on its own: it takes a
  # multi-year account with real audience AND recent posting history to cross.
  RELEASE_THRESHOLD = 70

  MAX_VERIFICATION_AGE = 180.days

  # Holds a social signal could plausibly speak to. Stripe pauses are
  # KYC/processor-side and seller self-pauses are intentional — social proof
  # answers neither, so they are excluded from the population rather than
  # logged as would-not-release noise.
  REVIEWABLE_RISK_STATES = %w[not_reviewed flagged_for_fraud flagged_for_tos_violation on_probation].freeze

  attr_reader :user

  def initialize(user)
    @user = user
  end

  def evaluate
    return nil unless held?

    best = scored_verifications.max_by { |scored| scored[:score] }
    score = best&.dig(:score) || 0
    shared_identity = best&.dig(:shared_identity_user_count).to_i.positive?

    {
      hold_source:,
      unpaid_balance_cents:,
      score:,
      would_have_released: score >= RELEASE_THRESHOLD && !shared_identity,
      signals: best,
    }
  end

  private
    def held?
      return false if user.deleted? || user.suspended?
      return false unless unpaid_balance_cents.positive?

      hold_source.present?
    end

    def hold_source
      @_hold_source ||=
        if user.payouts_paused_by_user?
          nil
        elsif user.payouts_paused_internally?
          source = user.payouts_paused_by_source
          source == User::PAYOUT_PAUSE_SOURCE_STRIPE ? nil : "payout_pause_#{source}"
        elsif REVIEWABLE_RISK_STATES.include?(user.user_risk_state) && !user.compliant?
          "risk_state_#{user.user_risk_state}"
        end
    end

    def unpaid_balance_cents
      @_unpaid_balance_cents ||= user.unpaid_balance_cents
    end

    def scored_verifications
      user.social_connect_verifications.filter_map do |verification|
        next if verification.last_verified_at.nil? || verification.last_verified_at < MAX_VERIFICATION_AGE.ago

        shared_identity_user_count = verification.shared_identity_user_ids.size
        components = score_components(verification)

        {
          platform: verification.platform,
          handle: verification.handle,
          score: components.values.sum,
          components:,
          shared_identity_user_count:,
        }
      end
    end

    def score_components(verification)
      age = verification.account_created_at
      {
        account_age: if age.nil? then 0
                     elsif age <= 2.years.ago then 30
                     elsif age <= 1.year.ago then 15
                     else 0
                     end,
        followers: if verification.follower_count.to_i >= 1_000 then 25
                   elsif verification.follower_count.to_i >= 100 then 10
                   else 0
                   end,
        post_depth: verification.post_count.to_i >= 100 ? 15 : 0,
        post_recency: verification.last_posted_at.present? && verification.last_posted_at >= 90.days.ago ? 15 : 0,
      }
    end
end
