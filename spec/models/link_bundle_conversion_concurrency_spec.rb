# frozen_string_literal: true

require "spec_helper"

describe Link, "concurrent bundle conversion and restore of the deleted parent bundle", :vcr do
  self.use_transactional_tests = false

  let!(:seller) { create(:user) }
  let!(:bundle) { create(:product, :bundle, user: seller) }
  let!(:product) { create(:product, user: seller, draft: true) }

  before do
    create(:bundle_product, bundle:, product:)
    bundle.mark_deleted!
  end

  after do
    product_ids = Link.where(user_id: seller.id).ids
    BundleProduct.where(bundle_id: product_ids).or(BundleProduct.where(product_id: product_ids)).delete_all
    Price.where(link_id: product_ids).delete_all
    Link.where(id: product_ids).delete_all
    RefundPolicy.where(seller_id: seller.id).delete_all
    UserComplianceInfo.where(user_id: seller.id).delete_all
    GlobalAffiliate.where(affiliate_user_id: seller.id).delete_all
    User.where(id: seller.id).delete_all
  end

  # Runs `first` to just before its commit, starts `second` and shows that it waits, then commits `first`.
  def run_overlapping(first:, second:)
    first_validated = Queue.new
    release_first = Queue.new
    results = Queue.new

    first_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          results << [:first, first.call]
          first_validated << true
          release_first.pop
        end
      rescue StandardError => e
        results << [:error, e]
      ensure
        first_validated << true
      end
    end
    first_validated.pop

    second_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          # Fixes this transaction's REPEATABLE READ snapshot before the first save commits.
          Link.where(id: [bundle.id, product.id]).to_a
          results << [:second, second.call]
        end
      rescue StandardError => e
        results << [:error, e]
      end
    end

    begin
      sleep 0.3
      expect(second_thread).to be_alive
    ensure
      release_first << true
    end
    [first_thread, second_thread].each { expect(_1.join(10)).to eq(_1) }

    outcomes = []
    outcomes << results.pop until results.empty?
    errors = outcomes.select { _1.first == :error }
    raise errors.first.last if errors.any?

    outcomes.to_h
  end

  it "takes the seller lock before checking a conversion" do
    seller_locked = Queue.new
    release_seller = Queue.new
    results = Queue.new

    locker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        User.find(seller.id).with_lock do
          seller_locked << true
          release_seller.pop
        end
      end
    end
    seller_locked.pop

    converter = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        results << Link.find(product.id).update(is_bundle: true)
      end
    end

    begin
      sleep 0.3
      expect(converter).to be_alive
    ensure
      release_seller << true
    end
    [locker, converter].each { expect(_1.join(10)).to eq(_1) }

    expect(results.pop).to eq(true)
    expect(Link.find(product.id)).to be_is_bundle
  end

  it "refuses the conversion when a restore of the deleted bundle commits first" do
    outcomes = run_overlapping(
      first: -> { Link.find(bundle.id).update(deleted_at: nil) },
      second: -> { Link.find(product.id).update(is_bundle: true) }
    )

    expect(outcomes).to eq(first: true, second: false)
    expect(Link.find(bundle.id)).to be_alive
    expect(Link.find(product.id)).not_to be_is_bundle
    expect(Link.alive.is_bundle.where(user_id: seller.id).ids).to eq([bundle.id])
  end

  it "refuses the restore when a conversion of its product commits first" do
    outcomes = run_overlapping(
      first: -> { Link.find(product.id).update(is_bundle: true) },
      second: -> { Link.find(bundle.id).update(deleted_at: nil) }
    )

    expect(outcomes).to eq(first: true, second: false)
    expect(Link.find(bundle.id)).to be_deleted
    expect(Link.find(product.id)).to be_is_bundle
    expect(Link.alive.is_bundle.where(user_id: seller.id).ids).to eq([product.id])
  end
end
