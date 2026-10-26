# frozen_string_literal: true

require "spec_helper"
require "timeout"

describe Link, "sales hold concurrency" do
  self.use_transactional_tests = false

  let!(:admin) { create(:admin_user) }
  let!(:seller) { create(:user) }
  let!(:product) { create(:product, user: seller) }

  after do
    user_ids = [admin.id, seller.id]
    product_ids = Link.where(user_id: user_ids).ids
    ProductSalesHold.where(product_id: product_ids).delete_all
    Price.where(link_id: product_ids).delete_all
    Link.where(id: product_ids).delete_all
    RefundPolicy.where(seller_id: user_ids).delete_all
    UserComplianceInfo.where(user_id: user_ids).delete_all
    GlobalAffiliate.where(affiliate_user_id: user_ids).delete_all
    User.where(id: user_ids).delete_all
  end

  def wait_for_row_lock(process_id:, table:)
    Timeout.timeout(10) do
      loop do
        lock_wait_count = ActiveRecord::Base.connection.select_value(<<~SQL.squish)
          SELECT COUNT(*)
          FROM performance_schema.data_lock_waits AS lock_waits
          INNER JOIN performance_schema.data_locks AS requested_lock
            ON requested_lock.ENGINE_LOCK_ID = lock_waits.REQUESTING_ENGINE_LOCK_ID
          INNER JOIN performance_schema.threads AS requesting_thread
            ON requesting_thread.THREAD_ID = lock_waits.REQUESTING_THREAD_ID
          WHERE requesting_thread.PROCESSLIST_ID = #{process_id.to_i}
            AND requested_lock.OBJECT_SCHEMA = DATABASE()
            AND requested_lock.OBJECT_NAME = #{ActiveRecord::Base.connection.quote(table)}
        SQL
        break if lock_wait_count.to_i.positive?

        sleep 0.01
      end
    end
  end

  # Pauses `first` once it holds the product row lock, starts `second` and waits until it is
  # blocked on that row, then lets `first` commit. Returns each side's result or error.
  def run_with_second_blocked_on_product(first:, second:)
    first_locked = Queue.new
    release_first = Queue.new
    second_connection_id = Queue.new
    outcomes = Queue.new

    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      next unless Thread.current[:sales_hold_first_writer]
      next unless payload[:sql].include?("FROM `links`") && payload[:sql].include?("FOR UPDATE")

      Thread.current[:sales_hold_first_writer] = false
      first_locked << true
      release_first.pop
    end

    first_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Thread.current[:sales_hold_first_writer] = true
        outcomes << [:first, first.call]
      rescue StandardError => e
        outcomes << [:first, e]
      ensure
        Thread.current[:sales_hold_first_writer] = false
        first_locked << true
      end
    end
    Timeout.timeout(10) { first_locked.pop }

    second_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        second_connection_id << ActiveRecord::Base.connection.select_value("SELECT CONNECTION_ID()")
        outcomes << [:second, second.call]
      rescue StandardError => e
        outcomes << [:second, e]
      end
    end
    wait_for_row_lock(process_id: Timeout.timeout(10) { second_connection_id.pop }, table: "links")
    expect(second_thread).to be_alive

    release_first << true
    [first_thread, second_thread].each { expect(_1.join(10)).to be_present }

    results = {}
    until outcomes.empty?
      side, value = outcomes.pop
      results[side] = value
    end
    results
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    release_first << true if release_first
    [first_thread, second_thread].compact.each do |thread|
      next if thread.join(1)

      thread.kill
      thread.join
    end
  end

  # The seller's copy is loaded while the listing is unpublished: publish! clearing an unpublish the
  # copy already saw is what puts it back on sale. A copy loaded while live has nothing to clear.
  it "refuses a seller publish that passed its first check before a hold committed" do
    product.unpublish!
    stale = Link.find(product.id)

    results = run_with_second_blocked_on_product(
      first: -> { Link.find(product.id).hold_sales!(seller:, held_by: admin) },
      second: -> { stale.publish! }
    )

    expect(results[:first].last).to be(true)
    expect(results[:second]).to be_a(Link::LinkInvalid)
    expect(results[:second].message).to eq(Link::UNPUBLISHED_BY_ADMIN_MESSAGE)
    expect(product.reload).not_to be_alive
    expect(product.active_sales_hold).to have_attributes(unpublished_listing: false)
  end

  # Negative control: the same interleaving relists a held listing when only the unlocked check runs.
  it "relists the held listing in that race without the check under the row lock" do
    allow_any_instance_of(Link).to receive(:enforce_no_active_sales_hold!).and_wrap_original do |original, lock: false|
      original.call(lock:) unless lock
    end
    product.unpublish!
    stale = Link.find(product.id)

    results = run_with_second_blocked_on_product(
      first: -> { Link.find(product.id).hold_sales!(seller:, held_by: admin) },
      second: -> { stale.publish! }
    )

    expect(results[:second]).not_to be_a(Exception)
    expect(product.reload).to be_alive
    expect(product.active_sales_hold).to be_present
  end

  it "takes a listing back off sale when its hold waited on a publish" do
    product.unpublish!

    results = run_with_second_blocked_on_product(
      first: -> { Link.find(product.id).publish! },
      second: -> { Link.find(product.id).hold_sales!(seller:, held_by: admin) }
    )

    expect(results[:first]).not_to be_a(Exception)
    expect(results[:second].last).to be(true)
    expect(product.reload).not_to be_alive
    expect(product.active_sales_hold).to have_attributes(unpublished_listing: true)
  end

  it "refuses a seller publish that passed its first check before an admin takedown committed" do
    product.unpublish!
    stale = Link.find(product.id)

    results = run_with_second_blocked_on_product(
      first: -> { Link.transaction { Link.lock.find(product.id).unpublish!(is_unpublished_by_admin: true) } },
      second: -> { stale.publish! }
    )

    expect(results[:second]).to be_a(Link::LinkInvalid)
    expect(product.reload).to be_is_unpublished_by_admin
    expect(product.purchase_disabled_at).to be_present
  end
end
