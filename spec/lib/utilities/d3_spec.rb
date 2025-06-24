# frozen_string_literal: true

require "spec_helper"

describe D3 do
  describe ".formatted_date" do
    it "returns 'Today' if date is today" do
      expect(described_class.formatted_date(Date.today)).to eq("Today")
      expect(described_class.formatted_date(Date.yesterday)).not_to eq("Today")
      expect(described_class.formatted_date(Date.new(2020, 1, 2), today_date: Date.new(2020, 1, 2))).to eq("Today")
    end

    it "returns date formatted" do
      expect(described_class.formatted_date(Date.new(2020, 5, 4))).to eq("May  4, 2020")
      expect(described_class.formatted_date(Date.new(2020, 12, 13))).to eq("Dec 13, 2020")
    end
  end

  describe ".formatted_date_with_timezone" do
    it "returns 'Today' if date is today" do
      expect(described_class.formatted_date_with_timezone(Date.today, Time.current.zone)).to eq("Today")
      expect(described_class.formatted_date_with_timezone(Date.yesterday, Time.current.zone)).not_to eq("Today")
    end

    it "returns date formatted" do
      expect(described_class.formatted_date_with_timezone(Time.utc(2020, 5, 4), "UTC")).to eq("May  4, 2020")
      expect(described_class.formatted_date_with_timezone(Time.utc(2020, 5, 4), "America/Los_Angeles")).to eq("May  3, 2020")
    end
  end

  describe "#date_domain" do
    it "returns date strings in 'Sunday, April 20th' format for given dates" do
      dates = Date.parse("2013-03-01")..Date.parse("2013-03-02")
      expect(D3.date_domain(dates)).to eq ["Friday, March 1st", "Saturday, March 2nd"]
    end
  end

  describe "#date_month_domain" do
    it "returns proper months for given dates in two different years" do
      dates = Date.parse("2018-12-31")..Date.parse("2019-01-01")
      expect(D3.date_month_domain(dates)).to eq [{ date: "Monday, December 31st", month: "December 2018", month_index: 0 }, { date: "Tuesday, January 1st", month: "January 2019", month_index: 1 }]
    end
  end
end
