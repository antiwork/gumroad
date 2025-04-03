# frozen_string_literal: true

class Product::ComputeCallAvailabilitiesService
  def initialize(product)
    @product = product
  end

  def perform
    return [] unless product.native_type == Link::NATIVE_TYPE_CALL

    Time.use_zone(product.user.timezone) do
      untaken_availabilities.map do |interval|
        interval
          .then { adjust_for_minimum_notice_period(_1) }
          .then { adjust_for_maximum_calls_per_day(_1) }
      end.compact
    end
  end

  private
    attr_reader :product
    delegate :call_availabilities, :sold_calls, :call_limitation_info, to: :product

    def untaken_availabilities
      availability_changes = Hash.new(0)
      all_availabilities.each do |interval|
        availability_changes[interval[:start_time]] += 1
        availability_changes[interval[:end_time]] -= 1
      end
      taken_availabilities.each do |interval|
        availability_changes[interval[:start_time]] -= 1
        availability_changes[interval[:end_time]] += 1
      end

      availabilities = []
      current_start = nil
      current_availability = 0

      availability_changes.sort_by(&:first).each do |time, availability_change|
        current_availability += availability_change

        if current_availability > 0
          current_start ||= time
        end

        if current_availability <= 0 && current_start
          availabilities << { start_time: current_start, end_time: time }
          current_start = nil
        end
      end

      availabilities
    end

    def adjust_for_minimum_notice_period(interval)
      return nil if interval.nil?
      return nil if interval[:end_time] < earliest_available_at

      interval[:start_time] = earliest_available_at if interval[:start_time] < earliest_available_at
      interval
    end

    def adjust_for_maximum_calls_per_day(interval)
      return nil if interval.nil?

      if !can_take_more_calls?(interval[:start_time])
        next_available_day = (interval[:start_time].to_date.next_day).upto(interval[:end_time].to_date)
          .find { can_take_more_calls?(_1) }

        return nil unless next_available_day
        interval[:start_time] = next_available_day.beginning_of_day
      end

      if !can_take_more_calls?(interval[:end_time])
        previous_available_day = (interval[:end_time].to_date.prev_day).downto(interval[:start_time].to_date)
          .find { can_take_more_calls?(_1) }

        return nil unless previous_available_day
        interval[:end_time] = previous_available_day.end_of_day
      end

      interval
    end

    def can_take_more_calls?(date)
      calls_per_day[date.to_date] < maximum_calls_per_day
    end

    def maximum_calls_per_day
      @_maximum_calls_per_day ||= call_limitation_info.maximum_calls_per_day || Float::INFINITY
    end

    def earliest_available_at
      @_earliest_available_at ||= call_limitation_info.minimum_notice_in_minutes&.minutes&.from_now || Time.current
    end

    def calls_per_day
      @_calls_per_day ||= taken_availabilities.each_with_object(Hash.new(0)) do |interval, hash|
        # Do not count end time's date towards the number of calls, to allow for
        # maximum number of sales.
        # Even if the call spans 3+ days (however unlikely), the middle day
        # would be fully booked and would not have any more availabilities.
        hash[interval[:start_time].to_date] += 1
      end
    end

    def all_availabilities
      @_all_availabilities ||= fetch_intervals(call_availabilities.upcoming.ordered_chronologically)
    end

    def taken_availabilities
      @_taken_availabilities ||= fetch_intervals(sold_calls.occupies_availability.upcoming.ordered_chronologically)
    end

    def fetch_intervals(relation)
      relation
        .pluck(:start_time, :end_time)
        .map { |start_time, end_time| { start_time:, end_time: } }
        .then { group_overlapping_intervals(_1) }
    end

    def group_overlapping_intervals(sorted_intervals)
      sorted_intervals.each_with_object([]) do |interval, grouped|
        if grouped.empty? || interval[:start_time] > grouped.last[:end_time]
          grouped << interval
        else
          grouped.last[:end_time] = [grouped.last[:end_time], interval[:end_time]].max
        end
      end
    end
end
