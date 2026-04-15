# frozen_string_literal: true

class CreatorAnalytics::Following
  include ConfirmedFollowerEvent::Events

  attr_reader :user

  def initialize(user)
    @user = user
  end

  def by_date(start_date:, end_date:)
    dates = (start_date .. end_date).to_a
    today_in_time_zone = Time.current.in_time_zone(user.timezone).to_date
    stored_first_follower_date = first_follower_date
    counts_data = stored_first_follower_date ? counts(dates) : zero_counts(dates)

    {
      dates: D3.date_domain(dates),
      start_date: D3.formatted_date(start_date, today_date: today_in_time_zone),
      end_date: D3.formatted_date(end_date, today_date: today_in_time_zone),
      by_date: counts_data,
      first_follower_date: (D3.formatted_date(stored_first_follower_date, today_date: today_in_time_zone) if stored_first_follower_date),
      new_followers: counts_data.fetch(:new_followers).sum - counts_data.fetch(:followers_removed).sum,
    }
  end

  # This method is used for displaying the running total of followers.
  # net_total = added - removed
  def net_total(before_date: nil)
    must = [{ range: { timestamp: { time_zone: user.timezone_id, lt: before_date.to_s } } }] if before_date
    aggs = ADDED_AND_REMOVED.index_with do |name|
      { filter: { term: { name: } }, aggs: { count: { value_count: { field: "name" } } } }
    end
    body = {
      query: { bool: { filter: [{ term: { followed_user_id: user.id } }], must: } },
      aggs:,
      size: 0
    }
    aggregations = ConfirmedFollowerEvent.search(body).aggregations
    added_count, removed_count = ADDED_AND_REMOVED.map do |name|
      aggregations.dig(name, :count, :value) || 0
    end
    added_count - removed_count
  end

  def first_follower_date
    body = {
      query: { bool: { filter: [{ term: { followed_user_id: user.id } }] } },
      sort: [{ timestamp: { order: :asc } }],
      _source: [:timestamp],
      size: 1
    }
    result = ConfirmedFollowerEvent.search(body).results.first
    return if result.nil?

    Time.parse(result._source.timestamp).in_time_zone(user.timezone).to_date
  end

  private
    # Returns hash of arrays for followers added, removed, and running net total from the start, for each day.
    def counts(dates)
      start_date, end_date = dates.first, dates.last
      names_aggs = ADDED_AND_REMOVED.index_with do |name|
        { filter: { term: { name: } }, aggs: { count: { value_count: { field: "name" } } } }
      end
      body = {
        query: {
          bool: {
            filter: [{ term: { followed_user_id: user.id } }],
            must: [{ range: { timestamp: { time_zone: user.timezone_id, gte: start_date.to_s, lte: end_date.to_s } } }]
          }
        },
        aggs: {
          dates: {
            date_histogram: { time_zone: user.timezone_id, field: "timestamp", calendar_interval: "day" },
            aggs: names_aggs
          }
        },
        size: 0
      }
      aggs_by_date = ConfirmedFollowerEvent.search(body).aggregations.dates.buckets.each_with_object({}) do |bucket, hash|
        hash[Date.parse(bucket["key_as_string"])] = ADDED_AND_REMOVED.index_with do |name|
          bucket.dig(name, :count, :value) || 0
        end
      end

      net_total_before_start_date = net_total(before_date: start_date)
      result = { new_followers: [], followers_removed: [], totals: [] }
      (start_date .. end_date).each do |date|
        result[:new_followers] << (aggs_by_date.dig(date, ADDED) || 0)
        result[:followers_removed] << (aggs_by_date.dig(date, REMOVED) || 0)
        result[:totals] << ((result[:totals].last || net_total_before_start_date) + result[:new_followers].last - result[:followers_removed].last)
      end

      result
    end

    # same as `#counts`, but with zero for every day
    def zero_counts(dates)
      zeros = [0] * dates.size
      { new_followers: zeros, followers_removed: zeros, totals: zeros }
    end
end
