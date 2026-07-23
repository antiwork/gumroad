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

    it "weights partially refunded purchases by their net amount" do
      # $1 at 09:00 each day, plus one $4 sale at 15:00 that was 75% refunded — its
      # remaining $1 should weigh the same as one 09:00 sale, not its original $4.
      described_class::MINIMUM_DAYS_WITH_SALES.times do |i|
        create_sale(days_ago: i + 1, hour: 9)
      end
      partially_refunded = create_sale(days_ago: 1, hour: 15, price_cents: 400)
      create(:refund, purchase: partially_refunded, amount_cents: 300)

      curve = service.cumulative_fractions
      expect(curve[9]).to eq(0.875) # $7 of $8 net revenue by end of hour 9
      expect(curve[15]).to eq(1.0)
    end

    it "does not subtract refunds that terminally failed and were reversed" do
      described_class::MINIMUM_DAYS_WITH_SALES.times do |i|
        create_sale(days_ago: i + 1, hour: 9)
      end
      sale = create_sale(days_ago: 1, hour: 15, price_cents: 100)
      create(:refund, purchase: sale, amount_cents: 100, status: Refund::TERMINAL_FAILURE_STATUSES.first, balance_reversed_on_failure: true)

      curve = service.cumulative_fractions
      expect(curve[15]).to eq(1.0)
      expect(curve[14]).to eq(curve[9])
      expect(curve[15]).to be > curve[14] # the sale still counts at full weight
    end

    it "excludes sales of deleted products from the curve" do
      # The chart's default view only shows live products, so a deleted product's
      # historical sales must not shape the divisor. $1 at 09:00 each day on the live
      # product, plus a big deleted-product sale at 15:00 that must contribute nothing.
      described_class::MINIMUM_DAYS_WITH_SALES.times do |i|
        create_sale(days_ago: i + 1, hour: 9)
      end
      deleted_product = create(:product, user: seller, price_cents: 100, deleted_at: Time.current)
      created_at = (ActiveSupport::TimeZone.new(seller.timezone_id).now.beginning_of_day - 1.day) + 15.hours
      deleted_sale = build(:purchase, link: deleted_product, seller:, price_cents: 10_000, created_at:)
      deleted_sale.save!(validate: false)

      curve = service.cumulative_fractions
      expect(curve[9]).to eq(1.0)
      expect(curve[15]).to eq(1.0)
      expect(curve[14]).to eq(1.0) # nothing between 9am and 3pm either
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
      digest = Digest::SHA256.hexdigest(seller.links.alive.ids.sort.join(","))
      expect(Rails.cache.exist?("creator_analytics/hourly_sales_curve/v3/#{seller.id}/#{seller.timezone_id}/#{digest}")).to be(true)
    end

    it "recomputes immediately when the live-product set changes" do
      # The chart reflects a product deletion (or restore) on the next load, so a
      # cached curve built from the old live-product set must not be served for the
      # rest of the cache window — the population fingerprint in the key invalidates it.
      other_product = create(:product, user: seller, price_cents: 100)
      described_class::MINIMUM_DAYS_WITH_SALES.times do |i|
        create_sale(days_ago: i + 1, hour: 9)
      end
      created_at = (ActiveSupport::TimeZone.new(seller.timezone_id).now.beginning_of_day - 1.day) + 15.hours
      other_sale = build(:purchase, link: other_product, seller:, price_cents: 700, created_at:)
      other_sale.save!(validate: false)

      curve_with_both = service.cumulative_fractions
      expect(curve_with_both[9]).to eq(0.5) # $7 of $14 by end of hour 9

      other_product.update!(deleted_at: Time.current)
      curve_after_delete = described_class.new(seller:).cumulative_fractions
      expect(curve_after_delete[9]).to eq(1.0) # the deleted product's sales no longer shape the curve

      other_product.update!(deleted_at: nil)
      expect(described_class.new(seller:).cumulative_fractions).to eq(curve_with_both)
    end

    it "recomputes immediately when the seller changes their time zone" do
      # The curve buckets sales by hour in the seller's analytics time zone, and the
      # presenter sends the new zone to the frontend as soon as it changes — a cached
      # curve built under the old zone must not be served against it for the rest of
      # the cache window. The time zone in the key invalidates the entry.
      described_class::MINIMUM_DAYS_WITH_SALES.times do |i|
        create_sale(days_ago: i + 1, hour: 9)
      end

      pacific_curve = service.cumulative_fractions
      expect(pacific_curve[8]).to eq(0.0)
      expect(pacific_curve[9]).to eq(1.0)

      seller.update!(timezone: "Eastern Time (US & Canada)")
      eastern_curve = described_class.new(seller:).cumulative_fractions
      # The same sales land three hours later on the clock in Eastern time.
      expect(eastern_curve[11]).to eq(0.0)
      expect(eastern_curve[12]).to eq(1.0)
    end
  end
end
