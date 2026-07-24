# frozen_string_literal: true

# Answers one question for the analytics sales chart: by this time of day, what
# fraction of a typical day's revenue has this seller historically booked? The chart
# divides today's booked total by that fraction to project the end-of-day total,
# which fixes the systematic low bias of a uniform run rate for sellers whose buyers
# are concentrated in specific hours (overnight hours relative to the seller produce
# almost nothing, so a uniform extrapolation reads far too low for most of the day).
#
# Internally this builds a 24-bucket cumulative curve from the seller's trailing
# 28 days of countable sales (bucketed by hour in the seller's analytics time zone)
# and caches it, then interpolates the fraction at the requested time. Returns nil
# when recent history is too thin to be meaningful — callers fall back to the naive
# linear extrapolation.
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

  # Cumulative fraction (0..1) of a typical day's revenue booked by `now` (wall clock
  # in the seller's time zone), interpolated linearly within the current hour, or nil
  # when the seller's history is too thin to build a stable curve.
  def expected_fraction_of_day(now: Time.current)
    curve = cumulative_fractions
    return nil if curve.nil?

    local = now.in_time_zone(seller.timezone_id)
    previous = local.hour.positive? ? curve[local.hour - 1] : 0.0
    previous + (curve[local.hour] - previous) * (local.min / 60.0)
  end

  private
    attr_reader :seller

    # Array of 24 floats (cumulative revenue fraction by end of each hour, ending at
    # 1.0), or nil when history is too thin. The seller's time zone is part of the
    # cache key because the curve buckets sales by hour in that zone — after a time
    # zone change a fresh curve is built on the next load instead of serving the old
    # zone's buckets for up to CACHE_EXPIRES_IN.
    def cumulative_fractions
      # Rails.cache.fetch treats a stored nil as a miss, so wrap the result in a hash
      # to also cache the "no stable curve" answer instead of recomputing it every load.
      Rails.cache.fetch("creator_analytics/hourly_sales_curve/v4/#{seller.id}/#{seller.timezone_id}", expires_in: CACHE_EXPIRES_IN) do
        { curve: compute }
      end[:curve]
    end

    def compute
      time_zone = ActiveSupport::TimeZone.new(seller.timezone_id)
      return nil if time_zone.nil?

      # Whole days only: today is excluded because it's the partial day being projected.
      window_end = time_zone.now.beginning_of_day
      window_start = window_end - TRAILING_DAYS.days

      # Bucket by the seller's local calendar day and hour. Purchases are stored in
      # UTC, so shift by the zone's current UTC offset in SQL (always an integer, so
      # safe to interpolate). CONVERT_TZ with named zones isn't available (the MySQL
      # time zone tables aren't loaded), and a fixed offset is fine here: if a
      # daylight-saving transition falls inside the window, part of the history lands
      # one hour off, which barely perturbs a curve that only weights a projection.
      offset_seconds = window_end.utc_offset.to_i
      local_time_sql = "DATE_ADD(purchases.created_at, INTERVAL #{offset_seconds} SECOND)"

      by_day_and_hour = seller.sales
        .counts_towards_volume
        .where(created_at: window_start.utc...window_end.utc)
        .group(Arel.sql("DATE(#{local_time_sql})"), Arel.sql("HOUR(#{local_time_sql})"))
        .sum(:price_cents)

      days_with_sales = by_day_and_hour.filter_map { |(day, _hour), cents| day if cents.positive? }.uniq.size
      return nil if days_with_sales < MINIMUM_DAYS_WITH_SALES

      hourly_totals = Array.new(24, 0)
      by_day_and_hour.each do |(_day, hour), cents|
        hourly_totals[hour] += cents if hour.between?(0, 23)
      end
      total = hourly_totals.sum
      return nil unless total.positive?

      running = 0
      hourly_totals.map { |cents| (running += cents).to_f / total }
    end
end
