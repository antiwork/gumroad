# frozen_string_literal: true

require "spec_helper"

describe Link, "concurrent custom permalink claim and restore", :vcr do
  self.use_transactional_tests = false

  let!(:seller) { create(:user) }
  let!(:deleted) { create(:product, user: seller, deleted_at: Time.current) }
  let!(:claimer) { create(:product, user: seller) }

  after do
    product_ids = Link.where(user_id: seller.id).ids
    Price.where(link_id: product_ids).delete_all
    Link.where(id: product_ids).delete_all
    RefundPolicy.where(seller_id: seller.id).delete_all
    UserComplianceInfo.where(user_id: seller.id).delete_all
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
          Link.where(id: claimer.id).to_a
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

  it "refuses the claim when a restore of the deleted product commits first" do
    outcomes = run_overlapping(
      first: -> { Link.find(deleted.id).update(deleted_at: nil) },
      second: -> { Link.find(claimer.id).update(custom_permalink: deleted.unique_permalink) }
    )

    expect(outcomes).to eq(first: true, second: false)
    expect(Link.alive.where(user_id: seller.id).map(&:general_permalink)).to match_array([deleted.unique_permalink, claimer.unique_permalink])
  end

  it "refuses the restore when a claim of its URL commits first" do
    outcomes = run_overlapping(
      first: -> { Link.find(claimer.id).update(custom_permalink: deleted.unique_permalink) },
      second: -> { Link.find(deleted.id).update(deleted_at: nil) }
    )

    expect(outcomes).to eq(first: true, second: false)
    expect(Link.find(deleted.id)).to be_deleted
    expect(Link.fetch_leniently(deleted.unique_permalink, user: seller)).to eq(claimer)
  end
end
