# frozen_string_literal: true

require "spec_helper"

describe ProductBuildPlaySession do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:build) { create(:product_build, :live, product:) }
  let(:purchase) { create(:purchase, link: product) }
  let(:start) { Time.utc(2026, 11, 3, 12, 0, 0) }

  describe ".start!" do
    it "opens a session on the build's product, at the moment of the page load" do
      session = described_class.start!(product_build: build, purchase:, at: start)

      expect(session).to be_persisted
      expect(session.product_id).to eq(product.id)
      expect(session.product_build_id).to eq(build.id)
      expect(session.purchase_id).to eq(purchase.id)
      expect(session.started_at).to eq(start)
      expect(session.last_heartbeat_at).to eq(start)
      expect(session.duration_seconds).to eq(0)
    end
  end

  describe "#heartbeat!" do
    let(:session) { described_class.start!(product_build: build, purchase:, at: start) }

    it "measures the session through its last beat" do
      (1..10).each { |beat| session.heartbeat!(start + (beat * described_class::HEARTBEAT_INTERVAL)) }

      expect(session.last_heartbeat_at).to eq(start + 5.minutes)
      expect(session.duration_seconds).to eq(5.minutes.to_i)
    end

    it "keeps a session open while its beats are no further apart than the expiry" do
      session.heartbeat!(start + described_class::SESSION_EXPIRY)

      expect(session.reload).to be_open(start + described_class::SESSION_EXPIRY)
    end

    it "starts a new session at a beat after the expiry, leaving the expired one and its gap alone" do
      after_the_expiry = start + 1.hour

      resumed = session.heartbeat!(after_the_expiry)

      expect(resumed).not_to eq(session)
      expect(resumed).to have_attributes(started_at: after_the_expiry, last_heartbeat_at: after_the_expiry, purchase:, product_build: build)
      expect(session.reload.last_heartbeat_at).to eq(start)
      expect(session.duration_seconds).to eq(0)
    end
  end

  describe "#heartbeat! repeated after the expiry" do
    it "returns the replacement it already started instead of starting another" do
      session = described_class.start!(product_build: build, purchase:, at: start)

      first = session.heartbeat!(start + 1.hour)
      second = session.reload.heartbeat!(start + 1.hour + described_class::HEARTBEAT_INTERVAL)

      expect(second).to eq(first)
      expect(second.last_heartbeat_at).to eq(start + 1.hour + described_class::HEARTBEAT_INTERVAL)
      expect(described_class.where(purchase:).count).to eq(2)
    end

    it "starts the next session from the newest one when the replacement has expired too" do
      session = described_class.start!(product_build: build, purchase:, at: start)
      replacement = session.heartbeat!(start + 1.hour)
      next_replacement = replacement.heartbeat!(start + 2.hours)

      expect(described_class.find(session.id).heartbeat!(start + 2.hours + 5.seconds)).to eq(next_replacement)
      expect(described_class.where(purchase:).count).to eq(3)
    end
  end

  # A beat's time is taken before it waits for any lock, so beats can be recorded out of order.
  describe "#heartbeat! recorded out of order" do
    let(:session) { described_class.start!(product_build: build, purchase:, at: start) }

    it "keeps the later beat when an earlier one is recorded after it" do
      earlier_load = described_class.find(session.id)
      described_class.find(session.id).heartbeat!(start + 60.seconds)

      earlier_load.heartbeat!(start + 30.seconds)

      expect(session.reload.last_heartbeat_at).to eq(start + 60.seconds)
    end

    it "keeps the later beat when a beat that found the session expired is recorded after it" do
      stale = described_class.find(session.id)
      fresh = described_class.find(session.id)
      fresh.heartbeat!(start + 110.seconds)
      fresh.heartbeat!(start + 130.seconds)

      expect(stale.heartbeat!(start + 125.seconds)).to eq(session)
      expect(session.reload.last_heartbeat_at).to eq(start + 130.seconds)
    end

    it "never ends a replacement before it started when an earlier beat follows the link into it" do
      earlier_load = described_class.find(session.id)
      replacement = described_class.find(session.id).heartbeat!(start + 1.hour + 1.second)

      expect(earlier_load.heartbeat!(start + 1.hour)).to eq(replacement)
      expect(replacement.reload.last_heartbeat_at).to eq(start + 1.hour + 1.second)
      expect(replacement.duration_seconds).to eq(0)
    end
  end

  describe "#heartbeat! with another page open on the same purchase" do
    it "resumes into its own replacement, not a session another page started" do
      a = described_class.start!(product_build: build, purchase:, at: start)
      b = described_class.start!(product_build: build, purchase:, at: start + 3.minutes)

      resumed = a.heartbeat!(start + 4.minutes)

      expect(resumed).not_to eq(b)
      expect(resumed.started_at).to eq(start + 4.minutes)
      expect(b.reload.last_heartbeat_at).to eq(start + 3.minutes)
      expect(a.reload.heartbeat!(start + 5.minutes)).to eq(resumed)
    end
  end

  describe ".stats_by_product" do
    it "counts each product's sessions and averages their length" do
      other_product = create(:product, user: seller)
      other_build = create(:product_build, :live, product: other_product)
      second_build = create(:product_build, :live, product:, number: 2)

      long = described_class.start!(product_build: build, purchase:, at: start)
      long.update!(last_heartbeat_at: start + 4.minutes)
      short = described_class.start!(product_build: second_build, purchase: create(:purchase, link: product), at: start)
      short.update!(last_heartbeat_at: start + 2.minutes)
      described_class.start!(product_build: other_build, purchase: create(:purchase, link: other_product), at: start)

      stats = described_class.stats_by_product([product.id, other_product.id])

      expect(stats[product.id]).to eq(count: 2, average_seconds: 3.minutes.to_i)
      expect(stats[other_product.id]).to eq(count: 1, average_seconds: 0)
    end

    it "leaves out a product nobody played" do
      expect(described_class.stats_by_product([product.id])).to eq({})
    end
  end
end
