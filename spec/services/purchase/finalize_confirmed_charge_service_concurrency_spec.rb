# frozen_string_literal: true

require "spec_helper"
require "timeout"

# Two database connections racing on one client-confirmed charge. Committed rows are required for
# the second connection to see the first's work, so this group runs outside the test transaction
# and deletes everything it created afterwards.
describe Purchase::FinalizeConfirmedChargeService, "on concurrent connections" do
  include ClientConfirmedLateSuccessHelpers

  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:notified_errors) { [] }

  before do
    seller # materialize the helper's seller so cleanup always has this example's records to anchor on
    allow(ErrorNotifier).to receive(:notify) { |error, *| notified_errors << error }
  end

  after do
    clean_up_example_records(seller.id)
  end

  # Both connections commit (the race needs that), so the rows outlive the run and are deleted
  # explicitly, anchored on this example's seller. Deleting every row above a per-table ID
  # watermark would also delete what another local run commits to the shared test database.
  def clean_up_example_records(seller_id)
    purchase_ids = Purchase.where(seller_id:).pluck(:id)
    order_ids = OrderPurchase.where(purchase_id: purchase_ids).pluck(:order_id)
    link_ids = Link.where(user_id: seller_id).pluck(:id)

    [BalanceTransaction, UrlRedirect, ProcessorPaymentIntent, PurchaseRefundPolicy,
     PurchaseSalesTaxInfo, ChargePurchase, OrderPurchase].each do |model|
      model.where(purchase_id: purchase_ids).delete_all
    end
    Purchase.where(id: purchase_ids).delete_all
    Charge.where(seller_id:).delete_all
    Order.where(id: order_ids).delete_all
    Price.where(link_id: link_ids).delete_all
    Link.where(id: link_ids).delete_all
    [AudienceMember, RefundPolicy].each { |model| model.where(seller_id:).delete_all }
    # A user gets a GlobalAffiliate on creation, keyed by affiliate_user_id rather than seller_id.
    Affiliate.where(affiliate_user_id: seller_id).delete_all
    Balance.where(user_id: seller_id).delete_all
    User.where(id: seller_id).delete_all
  end

  def connection_id = Purchase.connection.select_value("SELECT CONNECTION_ID()")

  # A statement still running after a second on this tiny dataset is waiting on a row lock.
  # PROCESSLIST works whether or not performance_schema is enabled.
  def wait_for_lock_wait(process_id)
    Timeout.timeout(10) do
      loop do
        blocked = connection.select_value(<<~SQL.squish)
          SELECT COUNT(*) FROM information_schema.PROCESSLIST
          WHERE ID = #{process_id.to_i} AND COMMAND = 'Query' AND TIME >= 1
        SQL
        break if blocked.to_i.positive?

        sleep 0.05
      end
    end
  end

  # Runs the block on its own connection. When pause_on_purchase_lock is set, the thread stops
  # right after its first purchase row lock is granted, until release is pushed.
  def on_own_connection(pause_on_purchase_lock: nil, release: nil, connection_ids: Queue.new)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        connection_ids << connection_id
        subscriber = if pause_on_purchase_lock
          ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
            next unless Thread.current[:gp3085_pause] && payload[:sql].match?(/FROM `purchases`.*FOR UPDATE/m)

            Thread.current[:gp3085_pause] = false
            pause_on_purchase_lock << true
            release.pop
          end
        end
        Thread.current[:gp3085_pause] = !pause_on_purchase_lock.nil?
        yield
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
      end
    end
  end

  it "keeps a purchase booked when a failure webhook read it before the success committed" do
    order, charge, (purchase, *) = build_cart
    charge_intent = ChargeProcessor.get_charge_intent(charge.merchant_account, charge.stripe_payment_intent_id)
    locked = Queue.new
    release = Queue.new
    failure_connection = Queue.new

    threads = []
    begin
      threads << on_own_connection(pause_on_purchase_lock: locked, release:) do
        Order::FinalizeConfirmedChargeService.new(order: Order.find(order.id), charge: Charge.find(charge.id), charge_intent:).perform
      end
      Timeout.timeout(10) { locked.pop }
      threads << on_own_connection(connection_ids: failure_connection) { HandleStripeEventWorker.new.perform(failed_event(charge)) }
      wait_for_lock_wait(Timeout.timeout(10) { failure_connection.pop })
    ensure
      release << true
      threads.each { _1.join(60) || _1.kill }
    end
    threads.each(&:value) # re-raises anything a thread raised

    expect(purchase.reload).to be_successful
    expect(purchase.stripe_error_code).to be_nil
    expect(purchase.balance_transactions.count).to eq(1)
    expect(access_count([purchase])).to eq(1)
  end

  it "revives each failed purchase of a cart exactly once when two finalizers walk it in opposite orders" do
    order, charge, purchases = build_cart(items: 2)
    fail_via_webhook(charge)
    expect(purchases.map { _1.reload.purchase_state }).to eq(%w[failed failed])
    charge_intent = ChargeProcessor.get_charge_intent(charge.merchant_account, charge.stripe_payment_intent_id)
    locked = Queue.new
    release = Queue.new
    second_connection = Queue.new
    reversed_order = Order.find(order.id)
    allow(reversed_order).to receive(:purchases).and_return(Purchase.where(id: purchases.map(&:id)).order(id: :desc).to_a)

    threads = []
    begin
      threads << on_own_connection(pause_on_purchase_lock: locked, release:) do
        Order::FinalizeConfirmedChargeService.new(order: Order.find(order.id), charge: Charge.find(charge.id), charge_intent:).perform
      end
      Timeout.timeout(10) { locked.pop }
      threads << on_own_connection(connection_ids: second_connection) do
        Order::FinalizeConfirmedChargeService.new(order: reversed_order, charge_intent:).perform
      end
      wait_for_lock_wait(Timeout.timeout(10) { second_connection.pop })
    ensure
      release << true
      threads.each { _1.join(60) || _1.kill }
    end
    threads.each(&:value) # re-raises anything a thread raised

    expect(notified_errors.grep(ActiveRecord::Deadlocked)).to be_empty
    expect(purchases.map { _1.reload.purchase_state }).to eq(%w[successful successful])
    expect(BalanceTransaction.where(purchase_id: purchases.map(&:id)).count).to eq(2)
    expect(ledger_cents(purchases)).to eq(charge.amount_cents)
    expect(access_count(purchases)).to eq(2)
  end
end
