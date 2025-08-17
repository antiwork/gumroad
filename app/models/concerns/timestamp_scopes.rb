# frozen_string_literal: true

module TimestampScopes
  extend ActiveSupport::Concern

  included do
    scope :created_between, ->(range) { where(created_at: range) if range }
    scope :column_between_with_offset, lambda { |column_name, range, offset|
      where("date(convert_tz(#{table_name}.#{column_name}, '+00:00', ?)) BETWEEN ? AND ?", offset, range.first.to_s, range.last.to_s)
    }
    scope :created_at_between_with_offset, lambda { |range, offset|
      column_between_with_offset("created_at", range, offset)
    }
    scope :created_between_dates_in_timezone, lambda { |range, timezone|
      created_on_or_after_start_of_date_in_timezone(range.begin, timezone)
        .created_before_end_of_date_in_timezone(range.end, timezone)
    }
    scope :created_before_end_of_date_in_timezone, lambda { |day, timezone|
      where("#{table_name}.created_at < ?", day.tomorrow.in_time_zone(timezone).beginning_of_day)
    }
    scope :created_on_or_after_start_of_date_in_timezone, lambda { |day, timezone|
      where("#{table_name}.created_at >= ?", day.in_time_zone(timezone).beginning_of_day)
    }
  end
end
