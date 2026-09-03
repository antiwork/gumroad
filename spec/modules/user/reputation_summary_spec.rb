# frozen_string_literal: true

require "spec_helper"

describe User::ReputationSummary do
  let(:seller) { create(:user) }
  let(:product_one) { create(:product, user: seller) }
  let(:product_two) { create(:product, user: seller) }

  def create_stat(product, five: 0, four: 0, one: 0)
    total = five + four + one
    ProductReviewStat.create!(
      link: product,
      reviews_count: total,
      average_rating: total.zero? ? 0 : ((five * 5 + four * 4 + one).to_f / total).round(1),
      ratings_of_five_count: five,
      ratings_of_four_count: four,
      ratings_of_one_count: one,
    )
  end

  describe "#seller_reputation_summary" do
    context "when the flag is off" do
      it "returns nil even when thresholds are met" do
        create_stat(product_one, five: 8)
        create_stat(product_two, four: 4)

        expect(seller.seller_reputation_summary).to be_nil
      end
    end

    context "when the flag is on" do
      before { Feature.activate_user(:seller_reputation_summary, seller) }

      it "sums per-star counts across products and weights the average by review count" do
        create_stat(product_one, five: 8)
        create_stat(product_two, four: 3, one: 1)

        expect(seller.seller_reputation_summary).to eq(
          average: ((8 * 5 + 3 * 4 + 1).to_f / 12).round(1),
          count: 12,
          products_count: 2,
        )
      end

      it "returns nil below #{User::ReputationSummary::MIN_REVIEWS} reviews" do
        create_stat(product_one, five: 5)
        create_stat(product_two, four: 4)

        expect(seller.seller_reputation_summary).to be_nil
      end

      it "returns nil when reviews span fewer than #{User::ReputationSummary::MIN_PRODUCTS} products" do
        create_stat(product_one, five: 15)

        expect(seller.seller_reputation_summary).to be_nil
      end

      it "skips products that opted out of displaying reviews" do
        create_stat(product_one, five: 8)
        create_stat(product_two, four: 4)
        opted_out = create(:product, user: seller, display_product_reviews: false)
        create_stat(opted_out, one: 50)

        expect(seller.seller_reputation_summary).to eq(average: 4.7, count: 12, products_count: 2)
      end

      it "skips deleted products" do
        create_stat(product_one, five: 8)
        create_stat(product_two, four: 4)
        deleted = create(:product, user: seller, deleted_at: Time.current)
        create_stat(deleted, one: 50)

        expect(seller.seller_reputation_summary).to eq(average: 4.7, count: 12, products_count: 2)
      end

      it "skips draft products" do
        create_stat(product_one, five: 8)
        create_stat(product_two, four: 4)
        draft = create(:product, user: seller, purchase_disabled_at: nil, draft: true)
        create_stat(draft, one: 50)

        expect(seller.seller_reputation_summary).to eq(average: 4.7, count: 12, products_count: 2)
      end

      it "does not count another seller's products" do
        create_stat(product_one, five: 8)
        create_stat(product_two, four: 4)
        create_stat(create(:product), one: 50)

        expect(seller.seller_reputation_summary).to eq(average: 4.7, count: 12, products_count: 2)
      end

      it "excludes the given product and its reviews" do
        create_stat(product_one, five: 8)
        create_stat(product_two, four: 4)
        third = create(:product, user: seller)
        create_stat(third, five: 4)

        expect(seller.seller_reputation_summary(exclude_product: third)).to eq(average: 4.7, count: 12, products_count: 2)
      end

      it "returns nil when the exclusion drops the seller below the thresholds" do
        create_stat(product_one, five: 8)
        create_stat(product_two, four: 4)

        expect(seller.seller_reputation_summary(exclude_product: product_one)).to be_nil
      end
    end

    context "large catalogue (gumroad-private#2384)" do
      before { Feature.activate_user(:seller_reputation_summary, seller) }

      # The incident: an 11,633-product seller with zero nonzero review stats
      # had EVERY product/profile view scan the whole catalogue join. The rollup
      # must stay a single bounded aggregate regardless of catalogue size, and a
      # large zero-review catalogue must still yield nil, not an O(catalogue)
      # row materialisation per request.
      # Regression for gumroad-private#2384: the read path must not materialise
      # a ProductReviewStat/Link row per catalogue product, and the seller rollup
      # must be a cache hit that issues NO review-stat query once warmed.
      it "is a cache hit after warming, with no review-stat query issued" do
        create_stat(product_one, five: 8)
        create_stat(product_two, four: 4)
        seller.bump_reputation_summary_version

        # warm the cache
        expect(seller.seller_reputation_summary).to eq(average: 4.7, count: 12, products_count: 2)

        queries = []
        callback = ->(_name, _started, _finished, _id, payload) { queries << payload[:sql] }
        ::ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          3.times { expect(seller.seller_reputation_summary).to eq(average: 4.7, count: 12, products_count: 2) }
        end

        review_stat_queries = queries.count { |sql| sql.match?(/product_review_stats|JOIN\s+links/i) }
        # Warm cache: no review-stat join should run at all on subsequent reads.
        expect(review_stat_queries).to eq(0)
      end

      it "returns nil for a large zero-review catalogue" do
        Array.new(230) { create(:product, user: seller) }
        seller.bump_reputation_summary_version

        expect(seller.seller_reputation_summary).to be_nil
      end

      it "invalidates the cached rollup when the write funnel bumps the seller version" do
        create_stat(product_one, five: 8)
        create_stat(product_two, four: 4)
        expect(seller.seller_reputation_summary).to eq(average: 4.7, count: 12, products_count: 2)

        seller.bump_reputation_summary_version
        ProductReviewStat.find_by(link_id: product_one.id).update_with_added_rating(5)
        seller.bump_reputation_summary_version

        expect(seller.seller_reputation_summary[:count]).to eq(13)
      end

      it "does not shadow ActiveRecord#cache_key on User" do
        # gumroad-private#2384 panel catch: the module must NOT define its own
        # #cache_key/#cache_key_with_version or it would override the AR
        # Integration ones for every User and break fragment caching/ETags
        # (and repoint them at the reputation aggregate). The module's key
        # helper is deliberately named reputation_cache_key.
        expect(seller.cache_key).to start_with("users/")
        expect(seller.cache_key).not_to match(/seller_reputation_summary/)
      end
    end
  end

  describe "#bump_reputation_summary_version" do
    before { Feature.activate_user(:seller_reputation_summary, seller) }

    it "defers the bump to transaction commit so a concurrent read cannot cache pre-commit data" do
      expect do
        ActiveRecord::Base.transaction do
          seller.bump_reputation_summary_version
          expect(seller.reputation_summary_cache_signature).to eq(0)
        end
      end.to change { seller.reputation_summary_cache_signature }.by(1)
    end

    it "reports instead of raising when Redis is unavailable" do
      allow($redis).to receive(:incr).and_raise(Redis::BaseError)
      expect(ErrorNotifier).to receive(:notify).with(kind_of(Redis::BaseError), user_id: seller.id)

      expect { seller.bump_reputation_summary_version }.not_to raise_error
    end
  end

  describe "#reputation_summary_cache_signature" do
    before { Feature.activate_user(:seller_reputation_summary, seller) }

    it "never repeats after successive bumps (no expiry resets the counter)" do
      seller.bump_reputation_summary_version
      first = seller.reputation_summary_cache_signature
      seller.bump_reputation_summary_version

      expect($redis.ttl("#{described_class::CACHE_PREFIX}/version/#{seller.id}")).to eq(-1)
      expect(seller.reputation_summary_cache_signature).to eq(first + 1)
    end

    it "returns a never-matching value instead of raising when Redis is unreadable" do
      allow($redis).to receive(:get).and_raise(Redis::BaseError)
      expect(ErrorNotifier).to receive(:notify).with(kind_of(Redis::BaseError), user_id: seller.id)

      expect(seller.reputation_summary_cache_signature).to start_with("unavailable-")
    end
  end
end
