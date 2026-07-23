# frozen_string_literal: true

# Builds a seller's typical intra-day sales distribution: for each hour of the day (in
# the seller's analytics time zone), the cumulative fraction of a typical day's revenue
# booked by the END of that hour. The sales chart uses this to project today's
# end-of-day total — dividing today's booked total by the expected cumulative fraction
# at the current time instead of the elapsed clock fraction, which fixes the systematic
# low bias of a uniform run rate for sellers whose buyers are concentrated in specific
# hours (e.g. overnight hours relative to the seller produce almost nothing, so a
# uniform extrapolation reads far too low for most of the day).
#
# Returns nil when the seller's recent history is too thin to build a stable curve, in
# which case the frontend falls back to the naive linear extrapolation.
class CreatorAnalytics::HourlySalesCurve
  # How far back to look. Four full weeks so every weekday is represented equally and
  # the curve tracks the seller's current buyer base rather than ancient history.
  TRAILING_DAYS = 28

  # Require at least this many distinct days with sales in the window before trusting
  # the curve — with fewer, a couple of lucky hours would dominate the distribution and
  # the "seasonality" would just be noise.
  MINIMUM_DAYS_WITH_SALES = 7

  # The curve moves slowly (it summarizes 28 days), so recomputing it on every
  # analytics page load would be wasted work. A few hours of staleness is invisible.
  CACHE_EXPIRES_IN = 6.hours

  def initialize(seller:)
    @seller = seller
  end

  # Array of 24 floats (cumulative revenue fraction by end of each hour, ending at
  # 1.0), or nil when history is too thin.
  def cumulative_fractions
    # Rails.cache.fetch treats a stored nil as a miss, so wrap the result in a hash to
    # also cache the "no stable curve" answer instead of recomputing it every load.
    # Key is versioned: v2 nets out partial refunds, so a v1 entry must not be reused.
    Rails.cache.fetch("creator_analytics/hourly_sales_curve/v2/#{seller.id}", expires_in: CACHE_EXPIRES_IN) do
      { curve: compute }
    end[:curve]
  end

  private
    attr_reader :seller

    def compute
      time_zone = ActiveSupport::TimeZone.new(seller.timezone_id)
      return nil if time_zone.nil?

      # Whole days only: today is excluded because it's the partial day being projected.
      window_end = time_zone.now.beginning_of_day
      window_start = window_end - TRAILING_DAYS.days

      # Bucket by the seller's local calendar day and hour. Purchases are stored in
      # UTC, so shift by the zone's current UTC offset in SQL. CONVERT_TZ with named
      # zones isn't available (the MySQL time zone tables aren't loaded), and a fixed
      # offset is fine here: if a daylight-saving transition falls inside the window,
      # part of the history lands one hour off, which barely perturbs a curve that only
      # weights a projection.
      offset_seconds = window_end.utc_offset.to_i
      local_time_sql = "DATE_ADD(purchases.created_at, INTERVAL #{offset_seconds} SECOND)"
      local_day_and_hour = [Arel.sql("DATE(#{local_time_sql})"), Arel.sql("HOUR(#{local_time_sql})")]

      countable_sales = seller.sales
        .counts_towards_volume
        .where(created_at: window_start.utc...window_end.utc)

      net_by_day_and_hour = countable_sales
        .group(*local_day_and_hour)
        .sum(:price_cents)

      # The analytics totals this curve weighs are net of refunds and chargebacks, but
      # counts_towards_volume only excludes FULLY refunded purchases — a partially
      # refunded purchase would otherwise keep its full historical weight, and refunds
      # concentrated in particular hours would skew the divisor. Subtract each
      # purchase's effectively refunded amount from its original sale hour (the curve
      # describes when sales happen, so refund money is attributed to the purchase's
      # hour, not the refund's). Refund.effective is the same "money actually moved"
      # definition Purchase#amount_refunded_cents uses.
      Refund.effective
        .joins(:purchase)
        .merge(countable_sales)
        .group(*local_day_and_hour)
        .sum(:amount_cents)
        .each do |key, refunded_cents|
          net_by_day_and_hour[key] = (net_by_day_and_hour[key] || 0) - refunded_cents
        end

      days_with_sales = net_by_day_and_hour.filter_map { |(day, _hour), cents| day if cents.positive? }.uniq.size
      return nil if days_with_sales < MINIMUM_DAYS_WITH_SALES

      hourly_totals = Array.new(24, 0)
      net_by_day_and_hour.each do |(_day, hour), cents|
        hourly_totals[hour] += cents if hour.between?(0, 23)
      end
      # A refund can't exceed its purchase's price, so buckets shouldn't go negative —
      # clamp anyway so bad historical data can only flatten the curve, never break
      # the monotonicity the frontend validates.
      hourly_totals.map! { |cents| [cents, 0].max }
      total = hourly_totals.sum
      return nil unless total.positive?

      running = 0
      cumulative = hourly_totals.map do |cents|
        running += cents
        (running.to_f / total).round(4)
      end
      # Guard against rounding leaving the final bucket at 0.9999 — by construction the
      # full day accounts for all of the revenue.
      cumulative[23] = 1.0
      cumulative
    end
end
