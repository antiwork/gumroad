# frozen_string_literal: true

class CreatorAnalytics::DateQuery
  class << self
    def day_range(field:, start_date:, end_date:, timezone:)
      {
        range: {
          field => {
            gte: day_start(start_date, timezone:).iso8601,
            lt: day_start(end_date + 1.day, timezone:).iso8601,
          }
        }
      }
    end

    def before_day(field:, date:, timezone:)
      {
        range: {
          field => {
            lt: day_start(date, timezone:).iso8601,
          }
        }
      }
    end

    def day_start(date, timezone:)
      date.in_time_zone(timezone)
    end
  end
end
