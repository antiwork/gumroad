# frozen_string_literal: true

describe CreatorAnalytics::HourlySalesCurve do
  # Default user factory time zone is Pacific Time; freeze somewhere mid-day so the
  # trailing window sits entirely in the past and "now" has a well-defined local hour.
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 100) }
  let(:service) { described_class.new(seller:) }

  before do
    travel_to Time.utc(2026, 7, 15, 20, 0, 0) # 1:00 PM Pacific (PDT)
    Rails.cache.clear
  end

  after { travel_back }

  # Creates a successful purchase at the given local (seller time zone) hour, on the
  # local day `days_ago` days before today. Saved without validations so the spec never
  # touches Stripe (see the purchase-factory financial_transaction_validation) — this
  # service only reads price_cents/state/created_at.
  def create_sale(days_ago:, hour:, price_cents: 100)
    time_zone = ActiveSupport::TimeZone.new(seller.timezone_id)
    created_at = (time_zone.now.beginning_of_day - days_ago.days) + hour.hours
    purchase = build(:purchase, link: product, seller:, price_cents:, created_at:)
    purchase.save!(validate: false)
    purchase
  end

  # Seeds the minimum history for a stable curve: one sale at the given local hour on
  # each of the last MINIMUM_DAYS_WITH_SALES days.
  def seed_history(hour:, price_cents: 100)
    described_class::MINIMUM_DAYS_WITH_SALES.times do |i|
      create_sale(days_ago: i + 1, hour:, price_cents:)
    end
  end

  describe "#expected_fraction_of_day" do
    it "returns nil when the seller has no sales history" do
      expect(service.expected_fraction_of_day).to be_nil
    end

    it "returns nil when fewer days have sales than the minimum" do
      (described_class::MINIMUM_DAYS_WITH_SALES - 1).times do |i|
        create_sale(days_ago: i + 1, hour: 12)
      end
      expect(service.expected_fraction_of_day).to be_nil
    end

    it "returns the fraction of a typical day's revenue booked by the current local time" do
      # Each history day: $1 at 09:00 local and $3 at 18:00 local. At 1 PM local the
      # seller has historically booked $1 of $4.
      seed_history(hour: 9, price_cents: 100)
      seed_history(hour: 18, price_cents: 300)

      expect(service.expected_fraction_of_day).to eq(0.25)
    end

    it "reaches 1 once all of a typical day's sales hours have passed" do
      seed_history(hour: 9)
      expect(service.expected_fraction_of_day).to eq(1.0)
    end

    it "interpolates within the current hour" do
      # All revenue historically lands during the noon hour; at 12:30 local we expect
      # half of it to be booked.
      seed_history(hour: 12)
      travel_to Time.utc(2026, 7, 15, 19, 30, 0) # 12:30 Pacific
      expect(described_class.new(seller:).expected_fraction_of_day).to eq(0.5)
    end

    it "ignores sales from today and from before the trailing window" do
      seed_history(hour: 9)
      create_sale(days_ago: 0, hour: 20)                                   # today — partial day
      create_sale(days_ago: described_class::TRAILING_DAYS + 5, hour: 20)  # too old

      # If either excluded sale counted, its evening bucket would pull the current
      # (early-afternoon) fraction below 1.
      expect(service.expected_fraction_of_day).to eq(1.0)
    end

    it "excludes refunded purchases" do
      seed_history(hour: 9)
      refunded = create_sale(days_ago: 1, hour: 15)
      refunded.update_column(:stripe_refunded, true)

      # If the refunded 15:00 sale counted, its bucket (after "now") would pull the
      # current fraction below 1; excluded, everything is booked by 1 PM.
      expect(service.expected_fraction_of_day).to eq(1.0)
    end

    it "caches the computed curve" do
      seed_history(hour: 9)
      first = service.expected_fraction_of_day

      # New sales don't change the cached answer until the cache expires.
      create_sale(days_ago: 1, hour: 20, price_cents: 100_000)
      expect(described_class.new(seller:).expected_fraction_of_day).to eq(first)

      travel described_class::CACHE_EXPIRES_IN + 1.minute
      expect(described_class.new(seller:).expected_fraction_of_day).not_to eq(first)
    end

    it "caches a nil result for sellers without enough history" do
      expect(service.expected_fraction_of_day).to be_nil
      expect(Rails.cache.exist?("creator_analytics/hourly_sales_curve/v4/#{seller.id}/#{seller.timezone_id}")).to be(true)
    end

    it "builds a fresh curve when the seller changes their time zone" do
      # The curve buckets sales by hour in the seller's analytics time zone, so the
      # zone is part of the cache key — a curve built under the old zone is never
      # served after a change.
      seed_history(hour: 9)
      expect(service.expected_fraction_of_day).to eq(1.0) # noon Pacific, sales at 9am

      seller.update!(timezone: "Eastern Time (US & Canada)")
      # The same sales land at noon Eastern; local time is now 3pm Eastern, so the
      # noon-hour sales are fully booked — but the point is the value is recomputed
      # under the new zone (a stale Pacific curve would have been indexed wrong).
      expect(described_class.new(seller:).expected_fraction_of_day).to eq(1.0)
      expect(Rails.cache.exist?("creator_analytics/hourly_sales_curve/v4/#{seller.id}/#{seller.timezone_id}")).to be(true)
    end
  end
end
