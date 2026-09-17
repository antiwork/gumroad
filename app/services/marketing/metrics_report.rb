# frozen_string_literal: true

class Marketing::MetricsReport
  COHORTS = { "zero_sale" => %w[zero], "already_sells" => %w[under_100 at_least_100] }.freeze
  ARMS = %i[treatment holdout].freeze
  FOLLOWUP_DAYS = 90
  FIRST_SALE_DAYS = 7
  DEFAULT_RECOVERY_DAYS = 7
  DEFAULT_DETERIORATION_THRESHOLD = 0.001
  SUGGESTED_EMAIL_KEY = "marketing_launch_written_copy_digest"

  def initialize(window_start:, window_end:, cohort:, recovery_days: DEFAULT_RECOVERY_DAYS,
                 deterioration_threshold: DEFAULT_DETERIORATION_THRESHOLD)
    @window_start = window_start.to_time.utc
    @window_end = window_end.to_time.utc
    @cohort = cohort.to_s
    @recovery_days = recovery_days
    @deterioration_threshold = deterioration_threshold
    raise ArgumentError, "unknown cohort" unless COHORTS.key?(@cohort)
    raise ArgumentError, "window must contain exactly 90 complete days" unless @window_end == @window_start + FOLLOWUP_DAYS.days && @window_end <= Time.current
    raise ArgumentError, "invalid recovery days" unless recovery_days.is_a?(Integer) && recovery_days.between?(1, FOLLOWUP_DAYS)
    raise ArgumentError, "invalid deterioration threshold" unless deterioration_threshold.is_a?(Numeric) && deterioration_threshold.finite? && deterioration_threshold.between?(0, 1)
  end

  def call
    groups = ARMS.index_with { [] }
    Marketing::HoldoutAssignment.where(prior_sales_bucket: COHORTS.fetch(@cohort))
      .where("marketing_holdout_assigned_at < ?", @window_end).find_each do |assignment|
      groups[assignment.marketing_holdout? ? :holdout : :treatment] << seller_metrics(assignment)
    end
    safety = email_safety(groups)
    {
      window_start: @window_start.iso8601, window_end: @window_end.iso8601, cohort: @cohort,
      assigned_creators: groups.transform_values(&:size),
      baseline_creators: groups.transform_values { |rows| rows.count { _1[:baseline] } },
      first_sale: compare_counts(groups, :first_sale),
      repeat_purchase: compare_counts(groups, :repeat_purchase),
      net_revenue: revenue_comparison(groups),
      email_safety: safety,
      cart_recovery: compare_counts(groups, :cart_recovery),
      blocks_rollout: safety[:blocks_rollout],
      definitions: {
        first_sale: "Zero-sale assignments entering the window with 7 complete days; assignment is the publication proxy. First paid purchase must have a same-seller UTM last click within 7 days.",
        repeat_purchase: "Buyers with paid purchases before creator assignment, for creators assigned by window start; any retained non-renewal purchase in the report's 90 days. Includes buyers never emailed; email-linked repeats are diagnostic only.",
        net_revenue: "USD price_cents minus effective partial refunds, excluding fully refunded purchases, per creator assigned by window start, including inactive creators and subscription revenue. Refund state is as of report execution.",
        email_safety: "Customer purchase-linked deliveries only; follower deletions after the last delivery are an unsubscribe proxy, not complaint telemetry. Suggested origin follows the draft marker, including seller edits.",
        cart_recovery: "Newly first-published workflows in the window; unique carts with a complete recovery window after their first recorded send; same-cart order paid within the configured days. Exposure diagnostic, not an intention-to-treat estimate.",
        inference: "Two-sided pooled two-proportion tests are descriptive and do not adjust buyer/email/cart clustering or multiple comparisons; only revenue Welch inference uses creator-randomized units.",
        recovery_days: @recovery_days
      }
    }
  end

  def self.render(report)
    lines = ["Auto marketing: #{report[:cohort]}", "#{report[:window_start]} to #{report[:window_end]} (end exclusive)"]
    %i[first_sale repeat_purchase net_revenue cart_recovery].each do |metric|
      result = report.fetch(metric)
      arms = ARMS.map do |arm|
        value = result.fetch(arm)
        "#{arm}: n=#{value[:n]}, #{value.key?(:rate) ? "rate=#{value[:rate] || 'unavailable'}" : "USD cents/creator=#{value[:amount_cents] || 'unavailable'}"}"
      end
      lines << "#{metric}: #{arms.join('; ')}; p=#{result[:p_value] || 'unavailable'}"
    end
    lines << "Email safety: incomplete; complaints and follower-only delivery denominators unavailable."
    report[:email_safety][:by_origin].each do |origin, comparison|
      lines << "#{origin} unsubscribe proxy: #{ARMS.map { |arm| "#{arm}=#{comparison[arm][:successes]}/#{comparison[arm][:n]}" }.join('; ')}; p=#{comparison[:p_value] || 'unavailable'}"
    end
    lines << "Blocks rollout: #{report[:blocks_rollout]}"
    lines.concat(report.fetch(:definitions).map { |key, value| "#{key}: #{value}" }).join("\n")
  end

  private
    def paid(seller_id)
      Purchase.where(seller_id:).paid.not_chargedback_or_chargedback_reversed.not_is_bundle_product_purchase
    end

    def retained_nonrenewals(seller_id)
      paid(seller_id).where(stripe_partially_refunded: [nil, false])
        .where.not(id: Purchase.where(seller_id:).recurring_charge.select(:id))
    end

    def seller_metrics(assignment)
      seller_id = assignment.user_id
      baseline = assignment.marketing_holdout_assigned_at <= @window_start
      {
        baseline:,
        first_sale: first_sale(assignment),
        repeat_purchase: baseline ? repeat_purchase(seller_id, assignment.marketing_holdout_assigned_at) : [0, 0, 0],
        revenue: baseline ? net_revenue(seller_id) : nil,
        deliveries: deliveries(seller_id, [assignment.marketing_holdout_assigned_at, @window_start].max),
        cart_recovery: cart_recovery(assignment)
      }
    end

    def first_sale(assignment)
      assigned_at = assignment.marketing_holdout_assigned_at
      return [0, 0] unless assignment.prior_sales_bucket == "zero" && assigned_at >= @window_start && assigned_at + FIRST_SALE_DAYS.days <= @window_end

      first = retained_nonrenewals(assignment.user_id).order(:created_at, :id).first
      converted = first && first.created_at >= assigned_at && first.created_at < assigned_at + FIRST_SALE_DAYS.days && attributed?(first)
      [converted ? 1 : 0, 1]
    end

    def attributed?(purchase)
      last_click = UtmLinkDrivenSale.where(purchase_id: purchase.id).joins(:utm_link_visit)
        .where("utm_link_visits.created_at <= ? AND utm_link_visits.created_at >= ?", purchase.created_at, purchase.created_at - FIRST_SALE_DAYS.days)
        .order("utm_link_visits.created_at DESC", "utm_link_visits.id DESC").first
      last_click && last_click.utm_link.seller_id == purchase.seller_id
    end

    def repeat_purchase(seller_id, assigned_at)
      prior = retained_nonrenewals(seller_id).where("purchases.created_at < ?", assigned_at).where.not(email: [nil, ""])
      repeat = retained_nonrenewals(seller_id).where(created_at: window).where(email: prior.select(:email))
      recipients = SentPostEmail.joins(:post).where(installments: { seller_id: }).where(created_at: window)
      # A send marker is not delivery proof; this is diagnostic attribution, never the ITT denominator.
      email_linked = repeat.where(<<~SQL.squish, seller_id:, starts_at: @window_start)
        EXISTS (#{recipients.where('sent_post_emails.email = purchases.email AND sent_post_emails.created_at <= purchases.created_at').select('1').to_sql})
        OR EXISTS (
          SELECT 1 FROM email_infos
          INNER JOIN purchases recipients ON recipients.id = email_infos.purchase_id
          INNER JOIN installments ON installments.id = email_infos.installment_id
          WHERE installments.seller_id = :seller_id AND recipients.seller_id = :seller_id
            AND recipients.email = purchases.email
            AND email_infos.sent_at >= :starts_at AND email_infos.sent_at <= purchases.created_at
        )
      SQL
      [repeat.distinct.count(:email), prior.distinct.count(:email), email_linked.distinct.count(:email)]
    end

    def net_revenue(seller_id)
      total = 0
      paid(seller_id).where(created_at: window).includes(:refunds).find_each do |purchase|
        total += purchase.price_cents - purchase.amount_refunded_cents
      end
      total
    end

    def deliveries(seller_id, starts_at)
      result = {}
      CreatorContactingCustomersEmailInfo.joins(:installment, :purchase)
        .where(installments: { seller_id: }, purchases: { seller_id: })
        .where(delivered_at: starts_at...@window_end)
        .includes(:purchase, :installment).find_each do |info|
        key = [info.installment_id, info.purchase.email.to_s.downcase]
        next if key.last.blank?
        # TODO(send_origin_snapshot): replace the editable draft marker with immutable send-time provenance.
        origin = info.installment.json_data[SUGGESTED_EMAIL_KEY].present? ? :suggested : :hand_written
        row = { email: key.last, at: info.delivered_at, origin:, unsubscribed: false }
        result[key] = row if result[key].nil? || info.delivered_at < result[key][:at]
      end
      latest = result.values.group_by { _1[:email] }.transform_values { _1.max_by { |row| row[:at] } }
      Follower.where(followed_id: seller_id, deleted_at: starts_at...@window_end).find_each do |follower|
        row = latest[follower.email.to_s.downcase]
        row[:unsubscribed] = true if row && row[:at] <= follower.deleted_at
      end
      result.values.map { _1.except(:email, :at) }
    end

    def email_safety(groups)
      comparisons = %i[suggested hand_written].index_with do |origin|
        counts = groups.transform_values do |rows|
          delivered = rows.flat_map { _1[:deliveries] }.select { _1[:origin] == origin }
          Marketing::MetricsStatistics.proportion(delivered.count { _1[:unsubscribed] }, delivered.size)
        end
        counts.merge(p_value: Marketing::MetricsStatistics.two_proportion(*counts.values_at(*ARMS)))
      end
      overall = groups.transform_values do |rows|
        delivered = rows.flat_map { _1[:deliveries] }
        Marketing::MetricsStatistics.proportion(delivered.count { _1[:unsubscribed] }, delivered.size)
      end
      overall[:p_value] = Marketing::MetricsStatistics.two_proportion(*overall.values_at(*ARMS))
      deteriorated = [overall].any? do |comparison|
        treatment, holdout = comparison.values_at(*ARMS)
        treatment[:rate] && holdout[:rate] && treatment[:rate] - holdout[:rate] > @deterioration_threshold
      end
      # TODO(complaint_events): persist timestamped SendGrid/Resend complaints with a send identity; current handlers only update opt-out state.
      { **overall, by_origin: comparisons, complaints: ARMS.index_with { { n: nil, rate: nil, p_value: nil } },
                   complete: false, deteriorated:, threshold: @deterioration_threshold, blocks_rollout: true,
                   reason: "Incomplete safety telemetry cannot approve rollout; follower deletion is only an unsubscribe proxy." }
    end

    def cart_recovery(assignment)
      # TODO(auto_enabled_workflows): narrow by immutable enablement provenance when the one-tap producer persists it.
      workflows = Workflow.abandoned_cart_type.where(seller_id: assignment.user_id)
        .where(first_published_at: [@window_start, assignment.marketing_holdout_assigned_at].max...@window_end)
      sends = SentAbandonedCartEmail.joins(:installment).where(installments: { workflow_id: workflows.select(:id) })
        .where(created_at: @window_start...@window_end).group(:cart_id).minimum(:created_at)
      mature = sends.select { |_, sent_at| sent_at + @recovery_days.days <= @window_end }
      recovered = 0
      mature.each_slice(500) do |batch|
        Cart.where(id: batch.map(&:first)).includes(:order).each do |cart|
          next unless cart.order
          sent_at = mature.fetch(cart.id)
          recovered += 1 if cart.order.purchases.merge(retained_nonrenewals(assignment.user_id))
            .where(created_at: sent_at...(sent_at + @recovery_days.days)).exists?
        end
      end
      [recovered, mature.size]
    end

    def window = @window_start...@window_end

    def compare_counts(groups, metric)
      counts = groups.transform_values do |rows|
        Marketing::MetricsStatistics.proportion(rows.sum { _1.fetch(metric)[0] }, rows.sum { _1.fetch(metric)[1] })
      end
      if metric == :repeat_purchase
        ARMS.each { |arm| counts[arm][:email_linked_successes] = groups[arm].sum { _1.fetch(metric)[2] } }
      end
      counts.merge(p_value: Marketing::MetricsStatistics.two_proportion(*counts.values_at(*ARMS)))
    end

    def revenue_comparison(groups)
      samples = groups.transform_values { |rows| Marketing::MetricsStatistics.sample(rows.filter_map { _1[:revenue] }) }
      samples.merge(p_value: Marketing::MetricsStatistics.welch(*samples.values_at(*ARMS)))
    end
end
