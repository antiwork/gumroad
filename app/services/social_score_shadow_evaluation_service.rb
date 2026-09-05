# frozen_string_literal: true

# Log-only: computes whether verified social signals WOULD have released a
# held payout. Nothing here moves money or clears a hold.
class SocialScoreShadowEvaluationService
  # The default requires account age, audience, and recent posting history.
  RELEASE_THRESHOLD = 70
  # Instagram exposes no creation date, so require every available signal.
  RELEASE_THRESHOLDS = { "instagram" => 55 }.freeze

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

    best = scored_verifications.max_by do |scored|
      [scored[:meets_threshold] ? 1 : 0, scored[:score].fdiv(scored[:release_threshold])]
    end
    score = best&.dig(:score) || 0
    # ANY shared identity vetoes, not just the best-scoring verification's —
    # a fraudster's weakest linked account is still a link.
    shared_identity = scored_verifications.any? { |scored| scored[:shared_identity_user_count].positive? }

    {
      hold_source:,
      unpaid_balance_cents:,
      score:,
      would_have_released: scored_verifications.any? { _1[:meets_threshold] } && !shared_identity,
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
      # A self-pause or Stripe pause must not mask a coexisting reviewable
      # hold — fall through to the risk state rather than returning early.
      @_hold_source ||= internal_pause_source || risk_state_source
    end

    def internal_pause_source
      return nil unless user.payouts_paused_internally?

      source = user.payouts_paused_by_source
      source == User::PAYOUT_PAUSE_SOURCE_STRIPE ? nil : "payout_pause_#{source}"
    end

    def risk_state_source
      return nil unless REVIEWABLE_RISK_STATES.include?(user.user_risk_state) && !user.compliant?

      "risk_state_#{user.user_risk_state}"
    end

    def unpaid_balance_cents
      @_unpaid_balance_cents ||= user.unpaid_balance_cents
    end

    def scored_verifications
      user.social_connect_verifications.filter_map do |verification|
        next if verification.last_verified_at.nil? || verification.last_verified_at < MAX_VERIFICATION_AGE.ago

        shared_identity_user_count = verification.shared_identity_user_ids.size
        components = score_components(verification)

        score = components.values.sum
        release_threshold = RELEASE_THRESHOLDS.fetch(verification.platform, RELEASE_THRESHOLD)

        {
          platform: verification.platform,
          handle: verification.handle,
          score:,
          release_threshold:,
          meets_threshold: score >= release_threshold,
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
