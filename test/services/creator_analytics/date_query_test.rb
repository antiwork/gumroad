# frozen_string_literal: true

require "test_helper"

class CreatorAnalyticsDateQueryTest < ActiveSupport::TestCase
  self.described_class = CreatorAnalytics::DateQuery



  context_ CreatorAnalytics::DateQuery do
  context_ ".day_range" do
  test "builds explicit datetime bounds for dates with a midnight DST gap" do
        result = described_class.day_range(
          field: :timestamp,
          start_date: Date.new(2026, 3, 22),
          end_date: Date.new(2026, 3, 22),
          timezone: "Tehran"
        )

        expect(result).to eq(
          range: {
            timestamp: {
              gte: Date.new(2026, 3, 22).in_time_zone("Tehran").iso8601,
              lt: Date.new(2026, 3, 23).in_time_zone("Tehran").iso8601,
            }
          }
        )
        expect(result.dig(:range, :timestamp)).not_to have_key(:time_zone)
      end
    end

  context_ ".before_day" do
  test "builds an explicit start-of-day instant for exclusive upper bounds" do
        result = described_class.before_day(field: :created_at, date: Date.new(2026, 3, 22), timezone: "Tehran")

        expect(result).to eq(
          range: {
            created_at: {
              lt: Date.new(2026, 3, 22).in_time_zone("Tehran").iso8601,
            }
          }
        )
      end
    end
  end
end
