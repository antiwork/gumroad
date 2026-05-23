# frozen_string_literal: true

require "test_helper"

class TimestampScopesTest < ActiveSupport::TestCase
  self.described_class = TimestampScopes



  context_ TimestampScopes do
    before do
      @purchase = create(:purchase, created_at: Time.utc(2020, 3, 9, 6, 30)) # Sun, 08 Mar 2020 23:30:00 PDT -07:00
    end

  context_ ".created_between" do
  test "returns records matching range" do
        expect(Purchase.created_between(Time.utc(2020, 3, 3)..Time.utc(2020, 3, 6))).to match_array([])
        expect(Purchase.created_between(Date.new(2020, 3, 3)..Date.new(2020, 3, 6))).to match_array([])

        expect(Purchase.created_between(Time.utc(2020, 3, 5)..Time.utc(2020, 3, 10))).to match_array([@purchase])
        expect(Purchase.created_between(Date.new(2020, 3, 5)..Date.new(2020, 3, 10))).to match_array([@purchase])
      end
    end

  context_ ".column_between_with_offset" do
  test "returns records matching range and offset" do
        expect(Purchase.column_between_with_offset("created_at", Date.new(2020, 3, 8)..Date.new(2020, 3, 8), "+00:00")).to match_array([])
        expect(Purchase.column_between_with_offset("created_at", Date.new(2020, 3, 9)..Date.new(2020, 3, 9), "+00:00")).to match_array([@purchase])
        expect(Purchase.column_between_with_offset("created_at", Date.new(2020, 3, 8)..Date.new(2020, 3, 8), "-07:00")).to match_array([@purchase])
      end
    end

  context_ ".created_at_between_with_offset" do
  test "returns records created within range and offset" do
        expect(Purchase.created_at_between_with_offset(Date.new(2020, 3, 8)..Date.new(2020, 3, 8), "+00:00")).to match_array([])
        expect(Purchase.created_at_between_with_offset(Date.new(2020, 3, 9)..Date.new(2020, 3, 9), "+00:00")).to match_array([@purchase])
        expect(Purchase.created_at_between_with_offset(Date.new(2020, 3, 8)..Date.new(2020, 3, 8), "-07:00")).to match_array([@purchase])
      end
    end

  context_ ".created_between_dates_in_timezone" do
  test "returns records matching range" do
        expect(Purchase.created_between_dates_in_timezone(Date.new(2020, 3, 8)..Date.new(2020, 3, 8), "America/Los_Angeles")).to match_array([@purchase])
        expect(Purchase.created_between_dates_in_timezone(Date.new(2020, 3, 8)..Date.new(2020, 3, 8), "UTC")).to match_array([])
      end
    end

  context_ ".created_before_end_of_date_in_timezone" do
  test "returns records matching date" do
        expect(Purchase.created_before_end_of_date_in_timezone(Date.new(2020, 3, 8), "America/Los_Angeles")).to match_array([@purchase])
        expect(Purchase.created_before_end_of_date_in_timezone(Date.new(2020, 3, 9), "America/Los_Angeles")).to match_array([@purchase])
        expect(Purchase.created_before_end_of_date_in_timezone(Date.new(2020, 3, 8), "UTC")).to match_array([])
        expect(Purchase.created_before_end_of_date_in_timezone(Date.new(2020, 3, 9), "UTC")).to match_array([@purchase])
      end
    end

  context_ ".created_on_or_after_start_of_date_in_timezone" do
  test "returns records matching date" do
        expect(Purchase.created_on_or_after_start_of_date_in_timezone(Date.new(2020, 3, 8), "America/Los_Angeles")).to match_array([@purchase])
        expect(Purchase.created_on_or_after_start_of_date_in_timezone(Date.new(2020, 3, 8), "UTC")).to match_array([@purchase])
        expect(Purchase.created_on_or_after_start_of_date_in_timezone(Date.new(2020, 3, 9), "UTC")).to match_array([@purchase])
        expect(Purchase.created_on_or_after_start_of_date_in_timezone(Date.new(2020, 3, 10), "UTC")).to match_array([])
      end
    end
  end
end
