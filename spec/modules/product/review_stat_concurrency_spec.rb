# frozen_string_literal: true

require "spec_helper"
require "timeout"

# Each update needs its own committed transaction and database connection to reproduce the
# first-row race between separate web processes.
describe Product::ReviewStat, "concurrency" do
  self.use_transactional_tests = false

  before do
    @seller = create(:user)
    @product = create(:product, user: @seller)
    @purchases = 2.times.map { create(:purchase, link: @product, seller: @seller) }
  end

  after do
    ProductReview.where(purchase_id: @purchases).delete_all
    Purchase.where(id: @purchases).delete_all
    ProductReviewStat.where(link_id: @product.id).delete_all
    Price.where(link_id: @product.id).delete_all
    @product.destroy!
    Affiliate.where(affiliate_user_id: @seller.id).delete_all
    RefundPolicy.where(seller_id: @seller.id).delete_all
    @seller.destroy!
  end

  it "counts concurrent first ratings without losing either update" do
    ready = Queue.new
    release = Queue.new
    allow_any_instance_of(Link).to receive(:product_review_stat).and_wrap_original do |method, *args|
      result = method.call(*args)
      if Thread.current[:review_stat_concurrency] && !Thread.current[:review_stat_checked]
        Thread.current[:review_stat_checked] = true
        ready << true
        release.pop
      end
      result
    end

    errors = Queue.new
    observed_counts = Queue.new
    threads = @purchases.zip([2, 5]).map do |purchase, rating|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Thread.current[:review_stat_concurrency] = true
          review = ProductReview.create!(purchase:, link: Link.find(@product.id), rating:)
          observed_counts << review.link.reviews_count
        rescue => e
          errors << e
        end
      end
    end

    2.times { Timeout.timeout(10) { ready.pop } }
    2.times { release << true }
    threads.each { expect(_1.join(20)).to be_present }

    expect(errors.size).to eq(0), -> { errors.size.times.map { errors.pop.full_message }.join("\n") }
    expect(2.times.map { observed_counts.pop }.sort).to eq([1, 2])
    expect(@product.reload.product_review_stat).to have_attributes(
      reviews_count: 2,
      average_rating: 3.5,
      ratings_of_two_count: 1,
      ratings_of_five_count: 1
    )
  ensure
    2.times { release << true } if release
    threads&.each do |thread|
      next if thread.join(1)

      thread.kill
      thread.join
    end
  end
end
