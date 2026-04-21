# frozen_string_literal: true

# Normalizes and clamps requested churn date ranges for a seller, exposing daily
# and monthly buckets.
#
class CreatorAnalytics::Churn::DateWindow
  DEFAULT_RANGE_DAYS = 30

  attr_reader :seller, :product_scope

  def initialize(seller:, product_scope:, start_date:, end_date:)
    @seller = seller
    @product_scope = product_scope
    @raw_start_date = start_date || default_start_date
    @raw_end_date = end_date || default_end_date
    @start_date, @end_date = clamp_dates(parse_date(@raw_start_date), parse_date(@raw_end_date))
  end

  attr_reader :start_date, :end_date

  def timezone_id
    seller.timezone_id
  end

  def daily_dates
    @daily_dates ||= (start_date..end_date).to_a
  end

  def monthly_dates
    @monthly_dates ||= daily_dates.group_by { |date| Date.new(date.year, date.month, 1) }.keys
  end

  private
    def parse_date(value)
      case value
      when Date
        value
      when Time
        value.in_time_zone(seller.timezone).to_date
      when String
        Date.parse(value)
      else
        raise CreatorAnalytics::Churn::InvalidDateRange, "Invalid date input: #{value.inspect}"
      end
    rescue ArgumentError => e
      raise CreatorAnalytics::Churn::InvalidDateRange, e.message
    end

    def clamp_dates(start_value, end_value)
      earliest = product_scope.earliest_analytics_date
      latest = default_end_date

      clamped_start = start_value.clamp(earliest, latest)
      clamped_end = end_value.clamp(clamped_start, latest)

      [clamped_start, clamped_end]
    end

    def default_start_date
      default_end_date - DEFAULT_RANGE_DAYS
    end

    def default_end_date
      @default_end_date ||= Time.current.in_time_zone(seller.timezone).to_date
    end
end
