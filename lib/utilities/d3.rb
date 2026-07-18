# frozen_string_literal: true

##
# A collection of D3 related helper methods.
##

class D3
  class << self
    def formatted_date(date, today_date: Date.today)
      date == today_date ? "Today" : date.strftime("%b %e, %Y")
    end

    def formatted_date_with_timezone(time, timezone)
      today_date = Time.current.in_time_zone(timezone).to_date
      date = time.in_time_zone(timezone).to_date
      formatted_date(date, today_date:)
    end

    def full_date_domain(dates)
      (0..dates.to_a.length - 1).map do |i|
        date = (dates.first + i)
        date.strftime("%B %e, %Y")
      end
    end

    def date_domain(dates)
      (0..dates.to_a.length - 1).map do |i|
        date = (dates.first + i)
        ordinalized_day = date.day.ordinalize
        date.strftime("%A, %B #{ordinalized_day}")
      end
    end

    # Like date_month_domain, but for hourly buckets. Takes the first instant of
    # each bucket (as times in the seller's timezone) and labels it with the
    # wall-clock hour, eg "Thursday, July 16th, 1 PM".
    def hour_month_domain(hours)
      last_month = nil
      month_index = -1
      hours.map do |hour|
        month = hour.strftime("%B %Y")

        if month != last_month
          last_month = month
          month_index = month_index + 1
        end

        {
          date: "#{hour.strftime("%A, %B")} #{hour.day.ordinalize}, #{hour.strftime("%l %p").strip}",
          month:,
          month_index:
        }
      end
    end

    def date_month_domain(dates)
      last_month = nil
      month_index = -1
      (0..dates.to_a.length - 1).map do |i|
        date = (dates.first + i)
        ordinalized_day = date.day.ordinalize

        # The formatted month string, eg "July 2019"
        month = date.strftime("%B %Y")

        # Each time we hit a new month, we increment the month_index
        if month != last_month
          last_month = month
          month_index = month_index + 1
        end

        {
          date: date.strftime("%A, %B #{ordinalized_day}"),
          month:,
          month_index:
        }
      end
    end
  end
end
