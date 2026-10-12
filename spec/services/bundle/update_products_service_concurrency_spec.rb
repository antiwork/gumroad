# frozen_string_literal: true

require "spec_helper"

describe Bundle::UpdateProductsService, "overlapping conversions", :vcr do
  self.use_transactional_tests = false

  let(:thread_wait_seconds) { 10 }
  let!(:seller) { create(:user) }
  let!(:bundle) { create(:product, user: seller, draft: true) }
  let!(:member) { create(:product, user: seller, draft: true) }
  let!(:other_product) { create(:product, user: seller, draft: true) }

  after do
    ActiveSupport::Notifications.unsubscribe(@membership_insert_subscriber) if @membership_insert_subscriber
    product_ids = Link.where(user_id: seller.id).ids
    BundleProduct.where(bundle_id: product_ids).or(BundleProduct.where(product_id: product_ids)).delete_all
    Price.where(link_id: product_ids).delete_all
    Link.where(id: product_ids).delete_all
    RefundPolicy.where(seller_id: seller.id).delete_all
    UserComplianceInfo.where(user_id: seller.id).delete_all
    GlobalAffiliate.where(affiliate_user_id: seller.id).delete_all
    User.where(id: seller.id).delete_all
  end

  def contents_of(product)
    [{ product_id: product.external_id, quantity: 1, position: 0 }]
  end

  def convert(product, contents)
    converting = Link.find(product.id)
    converting.is_bundle = true
    converting.native_type = Link::NATIVE_TYPE_BUNDLE
    described_class.new(bundle: converting, products: contents_of(contents)).perform.id
  end

  # Pauses the current thread once its bundle_products insert has run, so the other conversion starts while this
  # one holds uncommitted membership rows.
  def pause_after_membership_insert(written:, release:)
    Thread.current[:pause_after_membership_insert] = true
    @membership_insert_subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next unless Thread.current[:pause_after_membership_insert] && payload[:sql].start_with?("INSERT INTO `bundle_products`")

      Thread.current[:pause_after_membership_insert] = false
      written << true
      release.pop
    end
  end

  # SQL notifications fire only after a blocked query returns, so inspect the live performance schema.
  # The cached information_schema.innodb_trx view can lag this fresh wait.
  def wait_for_seller_lock_wait
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + thread_wait_seconds
    until seller_lock_waiting?
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
    true
  end

  def seller_lock_waiting?
    ActiveRecord::Base.connection.select_value(
      <<~SQL.squish
        SELECT COUNT(*) FROM performance_schema.data_lock_waits waits
        JOIN performance_schema.data_locks requested ON requested.ENGINE_LOCK_ID = waits.REQUESTING_ENGINE_LOCK_ID
        WHERE requested.OBJECT_SCHEMA = DATABASE() AND requested.OBJECT_NAME = 'users'
      SQL
    ).to_i.positive?
  end

  # `bundle` converts to hold `member`, while `member` converts to a bundle of its own. The second one's
  # conversion check waits on the first one's new membership row, so a first that writes it before locking the
  # seller deadlocks on the seller row the second then holds.
  it "serializes them on the seller instead of deadlocking" do
    membership_written = Queue.new
    release_first = Queue.new
    results = Queue.new
    threads = []

    begin
      first = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          pause_after_membership_insert(written: membership_written, release: release_first)
          results << [:first, convert(bundle, member)]
        rescue StandardError => e
          results << [:first_error, e]
        end
      end
      threads << first
      # Fails the example instead of hanging it if the first conversion never reaches its insert.
      expect(membership_written.pop(timeout: thread_wait_seconds)).to be(true)

      second = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          results << [:second, convert(member, other_product)]
        rescue StandardError => e
          results << [:second_error, e]
        end
      end
      threads << second

      expect(wait_for_seller_lock_wait).to be(true)
      expect(second).to be_alive
      expect(results).to be_empty
      release_first << true
      threads.each { expect(_1.join(thread_wait_seconds)).to eq(_1) }
    ensure
      release_first << true
      threads.each do |thread|
        thread.kill unless thread.join(thread_wait_seconds)
      end
    end

    outcomes = []
    outcomes << results.pop until results.empty?
    outcomes = outcomes.to_h

    expect(outcomes[:first_error]&.class).to be_nil
    expect(outcomes.keys).to contain_exactly(:first, :second_error)
    expect(outcomes[:second_error]).to be_a(ActiveRecord::RecordInvalid)
    expect(outcomes[:second_error].message).to include("already part of a bundle")
    expect(Link.find(bundle.id)).to be_is_bundle
    expect(Link.find(member.id)).not_to be_is_bundle
    expect(BundleProduct.alive.where(bundle_id: bundle.id).pluck(:product_id)).to eq([member.id])
    expect(BundleProduct.where(bundle_id: member.id)).to be_empty
  end
end
