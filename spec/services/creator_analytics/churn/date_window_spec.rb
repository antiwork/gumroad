# frozen_string_literal: true

require "spec_helper"

describe CreatorAnalytics::Churn::DateWindow do
  let(:seller) { create(:user, timezone: "UTC", created_at: Time.utc(2020, 1, 1)) }
  let(:product_scope) { CreatorAnalytics::Churn::ProductScope.new(seller:) }

  def create_product_with_purchase(created_at: nil, **product_options)
    product = create(:product, user: seller, **product_options)
    create(:purchase, link: product, created_at:)
    product
  end

  def date_in_seller_timezone(time)
    time.in_time_zone(seller.timezone).to_date
  end

  describe "#initialize" do
    context "with Date objects" do
      let(:start_date) { Date.new(2020, 1, 15) }
      let(:end_date) { Date.new(2020, 1, 20) }

      it "accepts Date objects" do
        window = described_class.new(
          seller:,
          product_scope:,
          start_date:,
          end_date:
        )

        expect(window.start_date).to eq(start_date)
        expect(window.end_date).to eq(end_date)
      end
    end

    context "with Time objects" do
      let(:start_time) { Time.utc(2020, 1, 15, 10, 30) }
      let(:end_time) { Time.utc(2020, 1, 20, 14, 45) }

      it "converts Time to Date in seller's timezone" do
        window = described_class.new(
          seller:,
          product_scope:,
          start_date: start_time,
          end_date: end_time
        )

        expect(window.start_date).to eq(date_in_seller_timezone(start_time))
        expect(window.end_date).to eq(date_in_seller_timezone(end_time))
      end
    end

    context "with String dates" do
      let(:start_date) { "2020-01-15" }
      let(:end_date) { "2020-01-20" }

      it "parses string dates" do
        window = described_class.new(
          seller:,
          product_scope:,
          start_date:,
          end_date:
        )

        expect(window.start_date).to eq(Date.parse(start_date))
        expect(window.end_date).to eq(Date.parse(end_date))
      end
    end

    context "with nil dates" do
      let(:today) { Time.current.in_time_zone(seller.timezone).to_date }

      it "uses default dates" do
        window = described_class.new(
          seller:,
          product_scope:,
          start_date: nil,
          end_date: nil
        )

        today = Time.current.in_time_zone(seller.timezone).to_date
        expect(window.end_date).to eq(today)
        expect(window.start_date).to eq(today - described_class::DEFAULT_RANGE_DAYS)
      end
    end

    context "with invalid date input" do
      it "raises InvalidDateRange for invalid types" do
        expect do
          described_class.new(
            seller:,
            product_scope:,
            start_date: 12345,
            end_date: Date.new(2020, 1, 20)
          )
        end.to raise_error(CreatorAnalytics::Churn::InvalidDateRange, /Invalid date input/)
      end

      it "raises InvalidDateRange for invalid string formats" do
        expect do
          described_class.new(
            seller:,
            product_scope:,
            start_date: "not-a-date",
            end_date: Date.new(2020, 1, 20)
          )
        end.to raise_error(CreatorAnalytics::Churn::InvalidDateRange)
      end
    end
  end

  describe "#start_date and #end_date" do
    context "when dates are within valid range" do
      let(:start_date) { Date.new(2020, 1, 15) }
      let(:end_date) { Date.new(2020, 1, 20) }

      it "returns the provided dates" do
        window = described_class.new(
          seller:,
          product_scope:,
          start_date:,
          end_date:
        )

        expect(window.start_date).to eq(start_date)
        expect(window.end_date).to eq(end_date)
      end
    end

    context "when start_date is before earliest_analytics_date" do
      let(:earliest_date) { Date.new(2020, 1, 10) }
      let(:start_date) { Date.new(2020, 1, 1) }
      let(:end_date) { Date.new(2020, 1, 20) }

      before do
        create_product_with_purchase(created_at: earliest_date.to_time)
      end

      it "clamps start_date to earliest_analytics_date" do
        window = described_class.new(
          seller:,
          product_scope:,
          start_date:,
          end_date:
        )

        expect(window.start_date).to eq(earliest_date)
        expect(window.end_date).to eq(end_date)
      end
    end

    context "when end_date is after today" do
      it "clamps end_date to today" do
        travel_to Time.utc(2020, 2, 1) do
          today = Time.current.in_time_zone(seller.timezone).to_date
          start_date = today - 10
          end_date = today + 5

          window = described_class.new(
            seller:,
            product_scope:,
            start_date:,
            end_date:
          )

          expect(window.start_date).to eq(start_date)
          expect(window.end_date).to eq(today)
        end
      end
    end

    context "when start_date is after end_date" do
      let(:start_date) { Date.new(2020, 1, 20) }
      let(:end_date) { Date.new(2020, 1, 15) }

      it "clamps end_date to start_date" do
        window = described_class.new(
          seller:,
          product_scope:,
          start_date:,
          end_date:
        )

        expect(window.start_date).to eq(start_date)
        expect(window.end_date).to eq(start_date)
      end
    end

    context "when seller has no sales" do
      let(:seller_created_at) { Time.utc(2020, 1, 1, 12, 0) }
      let(:start_date) { Date.new(2019, 12, 1) }
      let(:end_date) { Date.new(2020, 1, 20) }

      before do
        seller.update!(created_at: seller_created_at)
      end

      it "clamps start_date to seller created_at" do
        window = described_class.new(
          seller:,
          product_scope:,
          start_date:,
          end_date:
        )

        expect(window.start_date).to eq(date_in_seller_timezone(seller_created_at))
        expect(window.end_date).to eq(end_date)
      end
    end
  end

  describe "#timezone_id" do
    it "returns seller's timezone identifier" do
      window = described_class.new(
        seller:,
        product_scope:,
        start_date: Date.new(2020, 1, 15),
        end_date: Date.new(2020, 1, 20)
      )

      expect(window.timezone_id).to eq(seller.timezone_id)
    end
  end

  describe "#daily_dates" do
    let(:start_date) { Date.new(2020, 1, 15) }
    let(:end_date) { Date.new(2020, 1, 18) }

    it "returns an array of all dates in the range" do
      window = described_class.new(
        seller:,
        product_scope:,
        start_date:,
        end_date:
      )

      expect(window.daily_dates).to eq([
                                         Date.new(2020, 1, 15),
                                         Date.new(2020, 1, 16),
                                         Date.new(2020, 1, 17),
                                         Date.new(2020, 1, 18)
                                       ])
    end

    it "memoizes the result" do
      window = described_class.new(
        seller:,
        product_scope:,
        start_date:,
        end_date:
      )

      expect(window).to receive(:start_date).once.and_call_original
      expect(window).to receive(:end_date).once.and_call_original

      window.daily_dates
      window.daily_dates
    end
  end

  describe "#monthly_dates" do
    let(:start_date) { Date.new(2020, 1, 15) }
    let(:end_date) { Date.new(2020, 3, 10) }

    it "returns an array of first-of-month dates for each month in the range" do
      window = described_class.new(
        seller:,
        product_scope:,
        start_date:,
        end_date:
      )

      expect(window.monthly_dates).to eq([
                                           Date.new(2020, 1, 1),
                                           Date.new(2020, 2, 1),
                                           Date.new(2020, 3, 1)
                                         ])
    end

    it "memoizes the result" do
      window = described_class.new(
        seller:,
        product_scope:,
        start_date:,
        end_date:
      )

      expect(window).to receive(:daily_dates).once.and_call_original

      window.monthly_dates
      window.monthly_dates
    end
  end

  describe "timezone handling" do
    context "when seller timezone is Pacific Time" do
      let(:seller) { create(:user, timezone: "Pacific Time (US & Canada)") }
      let(:start_time) { Time.utc(2020, 1, 15, 8, 0) }
      let(:end_time) { Time.utc(2020, 1, 15, 16, 0) }

      before do
        create_product_with_purchase(created_at: Date.new(2020, 1, 1).to_time)
      end

      it "converts times to dates in seller's timezone" do
        window = described_class.new(
          seller:,
          product_scope:,
          start_date: start_time,
          end_date: end_time
        )

        expect(window.start_date).to eq(date_in_seller_timezone(start_time))
        expect(window.end_date).to eq(date_in_seller_timezone(end_time))
      end
    end
  end
end
