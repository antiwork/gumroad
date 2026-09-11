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
      note: "Skipped/unconnected rows are counted, not coerced to zero durations. hold_released comes from mark_compliant / payouts#resume Event hooks only. No auto-release threshold is computed.",
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
    lines << "  connected: n=#{held[:connected][:n]} time_to_review_hours=#{fmt_hours(held[:connected][:time_to_review_hours])} time_to_hold_released_hours=#{fmt_hours(held[:connected][:time_to_hold_released_hours])} time_to_first_payout_hours=#{fmt_hours(held[:connected][:time_to_first_payout_hours])}"
    lines << "  unconnected: n=#{held[:unconnected][:n]} time_to_review_hours=#{fmt_hours(held[:unconnected][:time_to_review_hours])} time_to_hold_released_hours=#{fmt_hours(held[:unconnected][:time_to_hold_released_hours])} time_to_first_payout_hours=#{fmt_hours(held[:unconnected][:time_to_first_payout_hours])}"
    lines << "  still_unreviewed connected=#{held[:connected][:still_unreviewed]} unconnected=#{held[:unconnected][:still_unreviewed]}"
    lines << "  still_held connected=#{held[:connected][:still_held]} unconnected=#{held[:unconnected][:still_held]}"
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
                        .map do |user_id, event_name, provider, surface, created_at|
                          { user_id:, event_name:, provider:, surface:, created_at: }
                        end
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

    def grouped_by_user_provider(rows)
      rows.group_by { [_1[:user_id], _1[:provider]] }
    end

    def later_event?(grouped, earlier)
      (grouped[[earlier[:user_id], earlier[:provider]]] || []).any? { _1[:created_at] >= earlier[:created_at] }
    end

    def first_later(rows, at:)
      rows.select { _1[:created_at] >= at }.min_by { _1[:created_at] }
    end

    def provider_metrics(provider)
      offered_rows = for_stage("offered", provider:)
      attempted_rows = for_stage("attempted", provider:)
      connected_rows = for_stage("connected", provider:)
      failed_rows = for_stage("failed", provider:)
      offered = first_by_user_provider(offered_rows)
      attempted = first_by_user_provider(attempted_rows)
      connected = first_by_user_provider(connected_rows)
      failed = first_by_user_provider(failed_rows)
      attempted_by_key = grouped_by_user_provider(attempted_rows)
      connected_by_key = grouped_by_user_provider(connected_rows)
      skipped = offered.values.count { |offer| !later_event?(attempted_by_key, offer) }
      attempted_without_connect = attempted.values.count { |attempt| !later_event?(connected_by_key, attempt) }

      {
        offered: offered.size,
        attempted: attempted.size,
        connected: connected.size,
        failed: failed.size,
        skipped_unattempted: skipped,
        abandonment_rate: rate(skipped, offered.size),
        failure_rate: rate(attempted_without_connect, attempted.size),
      }
    end

    def held_timing_metrics
      held_offers = for_stage("offered").select { _1[:surface] == HELD_SURFACE }
      first_offer = held_offers.group_by { _1[:user_id] }.transform_values { |group| group.min_by { _1[:created_at] } }
      connected_by_user = for_stage("connected").group_by { _1[:user_id] }
      reviews_by_user = for_stage("reviewed").group_by { _1[:user_id] }
      hold_releases_by_user = for_stage("hold_released").group_by { _1[:user_id] }
      payouts = first_completed_payouts_after(first_offer)
      connected_ids = first_offer.each_with_object(Set.new) do |(user_id, offer), set|
        set << user_id if first_later(connected_by_user[user_id] || [], at: offer[:created_at])
      end

      {
        connected: timing_bucket(first_offer, reviews_by_user, hold_releases_by_user, payouts, connected: true, connected_ids:),
        unconnected: timing_bucket(first_offer, reviews_by_user, hold_releases_by_user, payouts, connected: false, connected_ids:),
      }
    end

    def timing_bucket(first_offer, reviews_by_user, hold_releases_by_user, payouts, connected:, connected_ids:)
      users = first_offer.select { |user_id, _| connected_ids.include?(user_id) == connected }
      review_hours = []
      hold_hours = []
      payout_hours = []
      still_unreviewed = 0
      still_held = 0
      still_unpaid = 0

      users.each do |user_id, offer|
        review = first_later(reviews_by_user[user_id] || [], at: offer[:created_at])
        if review
          review_hours << hours_between(offer[:created_at], review[:created_at])
        else
          still_unreviewed += 1
        end
        hold_release = first_later(hold_releases_by_user[user_id] || [], at: offer[:created_at])
        if hold_release
          hold_hours << hours_between(offer[:created_at], hold_release[:created_at])
        else
          still_held += 1
        end
        payout_at = payouts[user_id]
        if payout_at
          payout_hours << hours_between(offer[:created_at], payout_at)
        else
          still_unpaid += 1
        end
      end

      {
        n: users.size,
        time_to_review_hours: summarize_hours(review_hours),
        time_to_hold_released_hours: summarize_hours(hold_hours),
        time_to_first_payout_hours: summarize_hours(payout_hours),
        still_unreviewed:,
        still_held:,
        still_unpaid:,
      }
    end

    def first_completed_payouts_after(offers_by_user)
      user_ids = offers_by_user.keys
      return {} if user_ids.empty?

      earliest_offer_at = offers_by_user.values.map { _1[:created_at] }.min
      Payment.where(user_id: user_ids, state: Payment::COMPLETED)
             .where("payments.created_at >= ?", earliest_offer_at)
             .pluck(:user_id, :created_at)
             .each_with_object({}) do |(user_id, created_at), hash|
               offer_at = offers_by_user.dig(user_id, :created_at)
               next if offer_at.blank? || created_at < offer_at

               current = hash[user_id]
               hash[user_id] = created_at if current.nil? || created_at < current
             end
    end

    def adverse_outcomes
      connected_rows = for_stage("connected")
      connected_at = connected_rows.group_by { _1[:user_id] }.transform_values { |group| group.min_by { _1[:created_at] }[:created_at] }
      connected_ids = connected_at.keys
      return { connected_users: 0, later_suspensions: 0, later_chargeback_sellers: 0 } if connected_ids.empty?

      {
        connected_users: connected_ids.size,
        later_suspensions: later_event_user_count(connected_at, later_suspension_times(connected_ids)),
        later_chargeback_sellers: later_event_user_count(connected_at, later_chargeback_times(connected_ids, connected_at.values.min)),
      }
    end

    def later_suspension_times(connected_ids)
      Comment.where(
        commentable_type: "User",
        commentable_id: connected_ids,
        comment_type: Comment::COMMENT_TYPE_SUSPENDED
      ).pluck(:commentable_id, :created_at)
    end

    def later_chargeback_times(connected_ids, earliest_connected_at)
      Purchase.chargedback.where(seller_id: connected_ids)
              .where("purchases.chargeback_date >= ?", earliest_connected_at)
              .pluck(:seller_id, :chargeback_date)
    end

    def later_event_user_count(connected_at, rows)
      rows.each_with_object(Set.new) do |(user_id, at), set|
        next if at.blank?

        connected = connected_at[user_id]
        set << user_id if connected.present? && at >= connected
      end.size
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
