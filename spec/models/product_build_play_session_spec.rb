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

    it "drops a beat that arrives after the expiry, so a page that stopped beating cannot extend it" do
      after_the_expiry = start + described_class::SESSION_EXPIRY + 1.second

      expect(session.heartbeat!(after_the_expiry)).to be(false)

      expect(session.reload.last_heartbeat_at).to eq(start)
      expect(session).not_to be_open(after_the_expiry)
      expect(session.duration_seconds).to eq(0)
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
