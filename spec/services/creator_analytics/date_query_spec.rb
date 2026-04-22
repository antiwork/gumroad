# frozen_string_literal: true

require "spec_helper"

describe CreatorAnalytics::DateQuery do
  describe ".day_range" do
    it "builds explicit datetime bounds for dates with a midnight DST gap" do
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

  describe ".before_day" do
    it "builds an explicit start-of-day instant for exclusive upper bounds" do
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
