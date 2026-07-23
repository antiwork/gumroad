# frozen_string_literal: true

describe CreatorAnalytics::HourlySalesCurve do
  # Default user factory time zone is Pacific Time; freeze somewhere mid-window so
  # relative day math is stable and the trailing window sits entirely in the past.
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 100) }
  let(:service) { described_class.new(seller:) }

  before do
    travel_to Time.utc(2026, 7, 15, 20, 0, 0) # noon Pacific
    Rails.cache.clear
  end

  after { travel_back }

  # Creates a successful $1 purchase at the given local (seller time zone) hour, on the
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

  describe "#cumulative_fractions" do
    it "returns nil when the seller has no sales history" do
      expect(service.cumulative_fractions).to be_nil
    end

    it "returns nil when fewer days have sales than the minimum" do
      (described_class::MINIMUM_DAYS_WITH_SALES - 1).times do |i|
        create_sale(days_ago: i + 1, hour: 12)
      end
      expect(service.cumulative_fractions).to be_nil
    end

    it "returns a 24-entry cumulative curve of the seller's hourly revenue distribution" do
      # 7 days, each with $1 at 09:00 local and $3 at 18:00 local.
      described_class::MINIMUM_DAYS_WITH_SALES.times do |i|
        create_sale(days_ago: i + 1, hour: 9, price_cents: 100)
        create_sale(days_ago: i + 1, hour: 18, price_cents: 300)
      end

      curve = service.cumulative_fractions
      expect(curve.length).to eq(24)
      expect(curve[0..7]).to all(eq(0.0)) # nothing before 9am
      expect(curve[9]).to eq(0.25)        # $1 of $4 by end of hour 9
      expect(curve[17]).to eq(0.25)       # flat until 6pm
      expect(curve[18]).to eq(1.0)        # everything booked by end of hour 18
      expect(curve[23]).to eq(1.0)
      expect(curve).to eq(curve.sort)     # monotonically non-decreasing
    end

    it "ignores sales from today and from before the trailing window" do
      described_class::MINIMUM_DAYS_WITH_SALES.times do |i|
        create_sale(days_ago: i + 1, hour: 9)
      end
      create_sale(days_ago: 0, hour: 3)                                   # today — partial day
      create_sale(days_ago: described_class::TRAILING_DAYS + 5, hour: 3)  # too old

      curve = service.cumulative_fractions
      expect(curve[3]).to eq(0.0)
      expect(curve[9]).to eq(1.0)
    end

    it "excludes refunded and chargedback purchases" do
      described_class::MINIMUM_DAYS_WITH_SALES.times do |i|
        create_sale(days_ago: i + 1, hour: 9)
      end
      refunded = create_sale(days_ago: 1, hour: 15)
      refunded.update_column(:stripe_refunded, true)

      curve = service.cumulative_fractions
      expect(curve[15]).to eq(curve[14]) # the refunded sale contributes nothing
      expect(curve[9]).to eq(1.0)
    end

    it "caches the computed curve" do
      described_class::MINIMUM_DAYS_WITH_SALES.times do |i|
        create_sale(days_ago: i + 1, hour: 9)
      end
      first = service.cumulative_fractions

      # New sales don't change the cached answer until the cache expires.
      create_sale(days_ago: 1, hour: 20, price_cents: 10_000)
      expect(described_class.new(seller:).cumulative_fractions).to eq(first)

      travel described_class::CACHE_EXPIRES_IN + 1.minute
      expect(described_class.new(seller:).cumulative_fractions).not_to eq(first)
    end

    it "caches a nil result for sellers without enough history" do
      expect(service.cumulative_fractions).to be_nil
      expect(Rails.cache.exist?("creator_analytics/hourly_sales_curve/#{seller.id}")).to be(true)
    end
  end
end
