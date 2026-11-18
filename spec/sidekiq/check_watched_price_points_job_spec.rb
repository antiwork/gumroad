# frozen_string_literal: true

require "spec_helper"

describe CheckWatchedPricePointsJob do
  let(:seller) { create(:user) }

  before { $redis.set(RedisKey.watched_price_point_sets, "1001,2002,3003,4004;9009,8008") }
  after { $redis.del(RedisKey.watched_price_point_sets) }

  def list(price_cents, **attrs)
    create(:product, user: seller, price_cents:, **attrs)
  end

  describe ".watched_sets" do
    it "parses sets and drops sets too small to ever match" do
      expect(described_class.watched_sets).to eq([[1001, 2002, 3003, 4004]])
    end

    it "returns no sets when none are configured" do
      $redis.del(RedisKey.watched_price_point_sets)
      expect(described_class.watched_sets).to eq([])
    end
  end

  describe "#perform" do
    it "flags the seller and records which prices matched" do
      [1001, 2002, 3003].each { list(_1) }

      described_class.new.perform(seller.id)

      expect(seller.reload.flagged_for_fraud?).to be(true)
      note = seller.comments.find_by(author_name: described_class::AUTHOR_NAME, comment_type: Comment::COMMENT_TYPE_FLAG_NOTE)
      expect(note.content).to include("10.01, 20.02, 30.03")
    end

    it "counts a variant's price (base plus difference)" do
      list(1001)
      list(2002)
      product = list(1000)
      category = create(:variant_category, link: product)
      create(:variant, variant_category: category, price_difference_cents: 2003)

      described_class.new.perform(seller.id)

      expect(seller.reload.flagged_for_fraud?).to be(true)
    end

    it "does not flag below the match threshold" do
      list(1001)
      list(2002)
      list(5000)

      described_class.new.perform(seller.id)

      expect(seller.reload.flagged?).to be(false)
    end

    it "ignores deleted listings" do
      list(1001)
      list(2002)
      list(3003, deleted_at: Time.current)

      described_class.new.perform(seller.id)

      expect(seller.reload.flagged?).to be(false)
    end

    it "does nothing when no sets are configured" do
      $redis.del(RedisKey.watched_price_point_sets)
      [1001, 2002, 3003].each { list(_1) }

      described_class.new.perform(seller.id)

      expect(seller.reload.flagged?).to be(false)
    end

    it "does not flag verified sellers" do
      seller.update!(verified: true)
      [1001, 2002, 3003].each { list(_1) }

      described_class.new.perform(seller.id)

      expect(seller.reload.flagged?).to be(false)
    end

    it "does not touch a suspended seller" do
      seller.update_columns(user_risk_state: "suspended_for_fraud")
      [1001, 2002, 3003].each { list(_1) }

      described_class.new.perform(seller.id)

      expect(seller.reload.suspended_for_fraud?).to be(true)
      expect(seller.comments.where(author_name: described_class::AUTHOR_NAME)).to be_empty
    end

    it "does not re-flag a seller a human has already cleared" do
      [1001, 2002, 3003].each { list(_1) }
      described_class.new.perform(seller.id)
      seller.reload.mark_compliant!(author_name: "admin")

      described_class.new.perform(seller.id)

      expect(seller.reload.compliant?).to be(true)
    end
  end

  describe "enqueueing" do
    it "enqueues a check when a listing is created or its price changes" do
      product = list(500)
      expect(described_class).to have_enqueued_sidekiq_job(seller.id).in(described_class::ENQUEUE_DELAY)

      described_class.jobs.clear
      product.update!(price_cents: 1001)
      expect(described_class).to have_enqueued_sidekiq_job(seller.id).in(described_class::ENQUEUE_DELAY)

      described_class.jobs.clear
      product.update!(name: "Renamed")
      expect(described_class).not_to have_enqueued_sidekiq_job(seller.id).in(described_class::ENQUEUE_DELAY)
    end

    it "enqueues nothing when no sets are configured" do
      $redis.del(RedisKey.watched_price_point_sets)
      list(1001)
      expect(described_class.jobs).to be_empty
    end
  end
end
