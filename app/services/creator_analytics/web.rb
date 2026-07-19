# frozen_string_literal: true

class CreatorAnalytics::Web
  def initialize(user:, dates:, products: nil, interval: "day")
    @user = user
    @dates = dates
    @_products = products
    # Validated by CreatorAnalytics::Sales/ProductPageViews, which also bound
    # hourly requests to CreatorAnalytics::Sales::MAX_HOURLY_DATE_RANGE_DAYS.
    @interval = interval
  end

  def by_date
    views_data = product_page_views.by_product_and_date
    sales_data = sales.by_product_and_date
    result = result_metadata
    result[:by_date] = { views: {}, sales: {}, totals: {} }

    %i[views sales totals].each do |type|
      product_permalinks.each do |product_id, product_permalink|
        result[:by_date][type][product_permalink] = dates_strings.map do |date|
          case type
          when :views then views_data[[product_id, date]]
          when :sales then sales_data.dig([product_id, date], :count)
          when :totals then sales_data.dig([product_id, date], :total)
          end || 0
        end
      end
    end

    result
  end

  def by_state
    views_data = product_page_views.by_product_and_country_and_state
    sales_data = sales.by_product_and_country_and_state
    result = { by_state: { views: {}, sales: {}, totals: {} } }
    usa = "United States"

    %i[views sales totals].each do |type|
      product_permalinks.each do |product_id, product_permalink|
        result[:by_state][type][product_permalink] = { usa => [0] * STATES_SUPPORTED_BY_ANALYTICS.size }
      end
    end

    views_data.each do |(product_id, country, state), count|
      product_permalink = product_permalinks[product_id]
      if country == usa
        state_index = STATES_SUPPORTED_BY_ANALYTICS.index(state)
        state_index = STATES_SUPPORTED_BY_ANALYTICS.index(STATE_OTHER) if state_index.blank?
        result[:by_state][:views][product_permalink][country][state_index] += count
      else
        result[:by_state][:views][product_permalink][country] ||= 0
        result[:by_state][:views][product_permalink][country] += count
      end
    end

    sales_data.each do |(product_id, country, state), values|
      product_permalink = product_permalinks[product_id]
      if country == usa
        state_index = STATES_SUPPORTED_BY_ANALYTICS.index(state)
        state_index = STATES_SUPPORTED_BY_ANALYTICS.index(STATE_OTHER) if state_index.blank?
        result[:by_state][:sales][product_permalink][country][state_index] += values[:count]
        result[:by_state][:totals][product_permalink][country][state_index] += values[:total]
      else
        result[:by_state][:sales][product_permalink][country] ||= 0
        result[:by_state][:sales][product_permalink][country] += values[:count]
        result[:by_state][:totals][product_permalink][country] ||= 0
        result[:by_state][:totals][product_permalink][country] += values[:total]
      end
    end

    result
  end

  def by_referral
    views_data = product_page_views.by_product_and_referrer_and_date
    sales_data = sales.by_product_and_referrer_and_date
    result = result_metadata
    result[:by_referral] = { views: {}, sales: {}, totals: {} }

    views_data.each do |(product_id, referrer, date), count|
      product_permalink = product_permalinks[product_id]
      referrer_name = referrer_domain_to_name(referrer)
      result[:by_referral][:views][product_permalink] ||= {}
      result[:by_referral][:views][product_permalink][referrer_name] ||= [0] * dates_strings.size
      result[:by_referral][:views][product_permalink][referrer_name][dates_strings.index(date)] = count
    end

    sales_data.each do |(product_id, referrer, date), values|
      product_permalink = product_permalinks[product_id]
      referrer_name = referrer_domain_to_name(referrer)
      result[:by_referral][:sales][product_permalink] ||= {}
      result[:by_referral][:sales][product_permalink][referrer_name] ||= [0] * dates_strings.size
      result[:by_referral][:sales][product_permalink][referrer_name][dates_strings.index(date)] = values[:count]
      result[:by_referral][:totals][product_permalink] ||= {}
      result[:by_referral][:totals][product_permalink][referrer_name] ||= [0] * dates_strings.size
      result[:by_referral][:totals][product_permalink][referrer_name][dates_strings.index(date)] = values[:total]
    end

    result
  end

  private
    def result_metadata
      # "Today" must be evaluated in the seller's time zone, not the server's: the
      # analytics day buckets follow the seller's configured time zone, and the frontend
      # keys behavior (like the projected end-of-day overlay) off the "Today" label.
      today_in_time_zone = Time.current.in_time_zone(@user.timezone).to_date
      metadata = {
        dates_and_months: @interval == "hour" ? D3.hour_month_domain(hourly_buckets.values) : D3.date_month_domain(@dates),
        start_date: D3.formatted_date(@dates.first, today_date: today_in_time_zone),
        end_date: D3.formatted_date(@dates.last, today_date: today_in_time_zone),
      }
      first_sale_created_at = @user.first_sale_created_at_for_analytics
      metadata[:first_sale_date] = D3.formatted_date_with_timezone(first_sale_created_at, @user.timezone) if first_sale_created_at
      metadata
    end

    def product_page_views
      CreatorAnalytics::ProductPageViews.new(user: @user, products:, dates: @dates, interval: @interval)
    end

    def sales
      CreatorAnalytics::Sales.new(user: @user, products:, dates: @dates, interval: @interval)
    end

    def products
      @_products ||= @user.products_for_creator_analytics.load
    end

    def product_permalinks
      @_product_id_to_permalink ||= products.to_h { |product| [product.id, product.unique_permalink] }
    end

    # The bucket keys the analytics services return for this interval, in order:
    # day keys ("2026-07-16") or seller-local hour keys ("2026-07-16T13:00").
    def dates_strings
      @_dates_strings ||= @interval == "hour" ? hourly_buckets.keys : @dates.map(&:to_s)
    end

    # Every wall-clock hour of the requested dates in the seller's timezone, as
    # { formatted key => first instant of that hour }. Walking instants (not labels)
    # keeps DST straight: a spring-forward day yields 23 keys, and on a fall-back
    # day the repeated hour keeps one key (the services merge its two Elasticsearch
    # buckets into one), so keys line up one-to-one with returned buckets.
    def hourly_buckets
      @_hourly_buckets ||= begin
        timezone = ActiveSupport::TimeZone[@user.timezone]
        time = timezone.local(@dates.first.year, @dates.first.month, @dates.first.day)
        # Resolve the end boundary from the day after the last date rather than
        # adding 1.day to the last date's midnight: in zones where DST starts at
        # midnight (e.g. Santiago), timezone.local shifts a nonexistent midnight
        # forward to 01:00, and "+ 1.day" from there would leak an extra next-day
        # hour into the domain.
        day_after_last = @dates.last + 1
        end_time = timezone.local(day_after_last.year, day_after_last.month, day_after_last.day)
        buckets = {}
        while time < end_time
          buckets[time.strftime("%Y-%m-%dT%H:%M")] ||= time
          time += 1.hour
        end
        buckets
      end
    end

    def referrer_domain_to_name(referrer_domain)
      return "direct" if referrer_domain.blank?
      return "Recommended by Gumroad" if referrer_domain == REFERRER_DOMAIN_FOR_GUMROAD_RECOMMENDED_PRODUCTS

      COMMON_REFERRERS_NAMES[referrer_domain] || referrer_domain
    end
end
