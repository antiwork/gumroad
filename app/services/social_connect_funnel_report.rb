# frozen_string_literal: true

# Reads SocialConnectFunnel Event rows. Does not write, score, or release holds.
class SocialConnectFunnelReport
  PROVIDERS = SocialConnectVerification::PLATFORMS
  HELD_SURFACE = "account_review"

  def initialize(since: 2.weeks.ago)
    @since = since
  end

  def to_h
    {
      since: @since.iso8601,
      generated_at: Time.current.iso8601,
      note: "Skipped/unconnected rows are counted, not coerced to zero durations. No auto-release threshold is computed.",
      per_provider: PROVIDERS.index_with { |provider| provider_metrics(provider) },
      held_sellers: held_timing_metrics,
      adverse_outcomes: adverse_outcomes,
    }
  end

  def to_text
    data = to_h
    lines = [
      "Social-connect funnel report",
      "since #{data[:since]}  generated #{data[:generated_at]}",
      data[:note],
      "",
    ]
    data[:per_provider].each do |provider, metrics|
      lines << "#{provider}:"
      lines << "  offered=#{metrics[:offered]} attempted=#{metrics[:attempted]} connected=#{metrics[:connected]} failed=#{metrics[:failed]}"
      lines << "  skipped_unattempted=#{fmt_count(metrics[:skipped_unattempted])} abandonment=#{fmt_rate(metrics[:abandonment_rate])}"
      lines << "  failure_rate=#{fmt_rate(metrics[:failure_rate])} (attempted without a later connected event)"
      lines << ""
    end
    held = data[:held_sellers]
    lines << "Held sellers (account_review offers):"
    lines << "  connected: n=#{held[:connected][:n]} time_to_review_hours=#{fmt_hours(held[:connected][:time_to_review_hours])} time_to_first_payout_hours=#{fmt_hours(held[:connected][:time_to_first_payout_hours])}"
    lines << "  unconnected: n=#{held[:unconnected][:n]} time_to_review_hours=#{fmt_hours(held[:unconnected][:time_to_review_hours])} time_to_first_payout_hours=#{fmt_hours(held[:unconnected][:time_to_first_payout_hours])}"
    lines << "  still_unreviewed connected=#{held[:connected][:still_unreviewed]} unconnected=#{held[:unconnected][:still_unreviewed]}"
    lines << "  still_unpaid connected=#{held[:connected][:still_unpaid]} unconnected=#{held[:unconnected][:still_unpaid]}"
    lines << ""
    adverse = data[:adverse_outcomes]
    lines << "Adverse outcomes after a connected event:"
    lines << "  connected_users=#{adverse[:connected_users]} later_suspensions=#{adverse[:later_suspensions]} later_chargeback_sellers=#{adverse[:later_chargeback_sellers]}"
    lines.join("\n")
  end

  private
    def events
      @_events ||= Event.where(event_name: SocialConnectFunnel::STAGES.map { SocialConnectFunnel.event_name(_1) })
                        .where("events.created_at >= ?", @since)
                        .pluck(:user_id, :event_name, :parent_referrer, :view_url, :created_at)
                        .map { |user_id, event_name, provider, surface, created_at|
                          { user_id:, event_name:, provider:, surface:, created_at: }
                        }
    end

    def stage_name(stage)
      SocialConnectFunnel.event_name(stage)
    end

    def for_stage(stage, provider: nil)
      name = stage_name(stage)
      rows = events.select { _1[:event_name] == name }
      rows = rows.select { _1[:provider] == provider } if provider
      rows
    end

    def first_by_user_provider(rows)
      rows.group_by { [_1[:user_id], _1[:provider]] }.transform_values { |group| group.min_by { _1[:created_at] } }
    end

    def provider_metrics(provider)
      offered = first_by_user_provider(for_stage("offered", provider:))
      attempted = first_by_user_provider(for_stage("attempted", provider:))
      connected = first_by_user_provider(for_stage("connected", provider:))
      failed = first_by_user_provider(for_stage("failed", provider:))
      skipped = offered.keys - attempted.keys
      attempted_without_connect = attempted.keys - connected.keys

      {
        offered: offered.size,
        attempted: attempted.size,
        connected: connected.size,
        failed: failed.size,
        skipped_unattempted: skipped.size,
        abandonment_rate: rate(skipped.size, offered.size),
        failure_rate: rate(attempted_without_connect.size, attempted.size),
      }
    end

    def held_timing_metrics
      held_offers = for_stage("offered").select { _1[:surface] == HELD_SURFACE }
      first_offer = held_offers.group_by { _1[:user_id] }.transform_values { |group| group.min_by { _1[:created_at] } }
      connected_ids = for_stage("connected").to_set { _1[:user_id] }
      reviews = for_stage("reviewed").group_by { _1[:user_id] }.transform_values { |group| group.min_by { _1[:created_at] } }
      payouts = first_completed_payouts_at(first_offer.keys)

      {
        connected: timing_bucket(first_offer, reviews, payouts, connected: true, connected_ids:),
        unconnected: timing_bucket(first_offer, reviews, payouts, connected: false, connected_ids:),
      }
    end

    def timing_bucket(first_offer, reviews, payouts, connected:, connected_ids:)
      users = first_offer.select { |user_id, _| connected_ids.include?(user_id) == connected }
      review_hours = []
      payout_hours = []
      still_unreviewed = 0
      still_unpaid = 0

      users.each do |user_id, offer|
        review = reviews[user_id]
        if review
          review_hours << hours_between(offer[:created_at], review[:created_at])
        else
          still_unreviewed += 1
        end
        payout_at = payouts[user_id]
        if payout_at && payout_at >= offer[:created_at]
          payout_hours << hours_between(offer[:created_at], payout_at)
        else
          still_unpaid += 1
        end
      end

      {
        n: users.size,
        time_to_review_hours: summarize_hours(review_hours),
        time_to_first_payout_hours: summarize_hours(payout_hours),
        still_unreviewed:,
        still_unpaid:,
      }
    end

    def first_completed_payouts_at(user_ids)
      return {} if user_ids.empty?

      Payment.where(user_id: user_ids, state: Payment::COMPLETED)
             .group(:user_id)
             .minimum(:created_at)
    end

    def adverse_outcomes
      connected_ids = for_stage("connected").map { _1[:user_id] }.uniq
      connected_at = for_stage("connected").group_by { _1[:user_id] }.transform_values { |group| group.min_by { _1[:created_at] }[:created_at] }
      return { connected_users: 0, later_suspensions: 0, later_chargeback_sellers: 0 } if connected_ids.empty?

      suspended = User.where(id: connected_ids, user_risk_state: %w[suspended_for_fraud suspended_for_tos_violation]).count
      chargeback_seller_ids = Purchase.chargedback.where(seller_id: connected_ids).distinct.pluck(:seller_id)
      later_chargebacks = chargeback_seller_ids.count do |seller_id|
        earliest = Purchase.chargedback.where(seller_id:).minimum(:chargeback_date)
        earliest.present? && earliest >= connected_at[seller_id]
      end

      {
        connected_users: connected_ids.size,
        later_suspensions: suspended,
        later_chargeback_sellers: later_chargebacks,
      }
    end

    def hours_between(from, to)
      ((to - from) / 1.hour).round(2)
    end

    def summarize_hours(values)
      return nil if values.empty?

      sorted = values.sort
      {
        n: sorted.size,
        p50: percentile(sorted, 0.5),
        p90: percentile(sorted, 0.9),
        mean: (sorted.sum / sorted.size).round(2),
      }
    end

    def percentile(sorted, fraction)
      return sorted.first if sorted.size == 1

      index = ((sorted.size - 1) * fraction).round
      sorted[index]
    end

    def rate(numerator, denominator)
      return nil if denominator.zero?

      (numerator.to_f / denominator).round(4)
    end

    def fmt_count(value)
      value.nil? ? "n/a" : value.to_s
    end

    def fmt_rate(value)
      value.nil? ? "n/a (no denominator)" : format("%.1f%%", value * 100)
    end

    def fmt_hours(summary)
      return "n/a (no completed intervals)" if summary.nil?

      "n=#{summary[:n]} p50=#{summary[:p50]} p90=#{summary[:p90]} mean=#{summary[:mean]}"
    end
end
