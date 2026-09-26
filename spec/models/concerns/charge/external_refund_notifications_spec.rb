# frozen_string_literal: true

require "spec_helper"

# Commit callbacks must see the handler's own transaction commit or roll back, so this file
# runs outside the fixture transaction and deletes the rows it inserted.
describe Charge::Refundable, "external refund notifications" do
  self.use_transactional_tests = false

  around do |example|
    inserted = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      table = payload[:sql].match(/\AINSERT INTO `([^`]+)`/)&.[](1)
      id = table && payload[:connection].raw_connection.last_id
      inserted << [table, id] if id&.positive?
    end
    example.run
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
    connection = ApplicationRecord.connection
    inserted.uniq.reverse_each do |table, id|
      connection.execute("DELETE FROM #{connection.quote_table_name(table)} WHERE id = #{Integer(id)}")
    end
  end

  let(:seller) { create(:user) }
  let(:merchant_account) { create(:merchant_account, user: seller) }
  let(:token) { SecureRandom.hex(6) }
  let(:refund_id) { "re_notify_#{token}" }

  before do
    allow(ErrorNotifier).to receive(:notify)
  end

  def create_purchase(price_cents, **attributes)
    create(:purchase_with_balance, link: create(:product, user: seller, price_cents:), seller:, merchant_account:,
                                   price_cents:, total_transaction_cents: price_cents,
                                   stripe_transaction_id: "ch_notify_#{token}", **attributes)
  end

  def stub_charge_refund(amount_cents)
    charge_refund = ChargeRefund.new
    charge_refund.id = refund_id
    charge_refund.charge_processor_id = StripeChargeProcessor.charge_processor_id
    charge_refund.flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, -amount_cents)
    charge_refund.instance_variable_set(:@refund, Stripe::StripeObject.construct_from(id: refund_id, status: "succeeded"))
    allow_any_instance_of(StripeChargeProcessor).to receive(:get_refund).and_return(charge_refund)
  end

  def build_event(refunded_amount_cents)
    ChargeEvent.new.tap do |event|
      event.charge_id = "ch_notify_#{token}"
      event.refund_id = refund_id
      event.extras = { refund_status: "succeeded", refunded_amount_cents:, refund_reason: nil }
    end
  end

  def refund_webhooks(purchase)
    PostToPingEndpointsWorker.jobs.select { _1["args"][0] == purchase.id && _1["args"][2] == ResourceSubscription::REFUNDED_RESOURCE_NAME }
  end

  def buyer_mails(purchase)
    ActiveJob::Base.queue_adapter.enqueued_jobs.select do |job|
      arguments = job[:args]
      arguments[0] == "CustomerMailer" && %w[refund partial_refund].include?(arguments[1]) && arguments.dig(3, "args", 2) == purchase.id
    end
  end

  def notification_counts(purchases)
    purchases.map { [refund_webhooks(_1).size, buyer_mails(_1).size] }
  end

  describe "a combined charge whose later purchase fails bookkeeping" do
    let!(:purchases) { [create_purchase(10_00, is_part_of_combined_charge: true), create_purchase(5_00, is_part_of_combined_charge: true)] }
    let!(:charge) { create(:charge, processor_transaction_id: "ch_notify_#{token}", amount_cents: 15_00, merchant_account:, purchases:) }
    let(:event) { build_event(15_00) }
    let(:refund_rows) { -> { Refund.where(processor_refund_id: refund_id).order(:purchase_id).pluck(:purchase_id, :amount_cents) } }

    before { stub_charge_refund(15_00) }

    it "enqueues each purchase's webhook and buyer mail once, only after the retry commits" do
      fail_second = true
      counts_inside_transaction = nil
      allow_any_instance_of(Purchase).to receive(:decrement_balance_for_refund_or_chargeback!).and_wrap_original do |method, *args, **kwargs|
        if method.receiver.id == purchases.last.id
          counts_inside_transaction = notification_counts(purchases)
          raise "second purchase bookkeeping failed" if fail_second
        end
        method.call(*args, **kwargs)
      end
      expect(ApplicationRecord.connection.open_transactions).to eq(0)
      balance_cents = seller.balances.sum(:amount_cents)

      expect { charge.handle_event_refund_updated!(event) }.to raise_error("second purchase bookkeeping failed")

      expect(ApplicationRecord.connection.open_transactions).to eq(0)
      expect(refund_rows.call).to be_empty
      expect(seller.balances.sum(:amount_cents)).to eq(balance_cents)
      expect(notification_counts(purchases)).to eq([[0, 0], [0, 0]])

      fail_second = false
      charge.reload.handle_event_refund_updated!(event)

      expect(counts_inside_transaction).to eq([[0, 0], [0, 0]])
      expect(refund_rows.call).to eq([[purchases.first.id, 10_00], [purchases.last.id, 5_00]])
      expect(seller.balances.sum(:amount_cents)).to be < balance_cents
      expect(notification_counts(purchases)).to eq([[1, 1], [1, 1]])
      purchases.each do |purchase|
        expect(refund_webhooks(purchase).sole["args"]).to eq([purchase.id, nil, ResourceSubscription::REFUNDED_RESOURCE_NAME])
        expect(buyer_mails(purchase).sole[:args][0..3]).to eq(["CustomerMailer", "refund", "deliver_now",
                                                               { "args" => [purchase.email, purchase.link_id, purchase.id], "_aj_ruby2_keywords" => ["args"] }])
      end

      charge.reload.handle_event_refund_updated!(event)

      expect(refund_rows.call.size).to eq(2)
      expect(notification_counts(purchases)).to eq([[1, 1], [1, 1]])
    end

    it "surfaces an enqueue failure after commit without rolling back the booked refunds" do
      allow(PostToPingEndpointsWorker).to receive(:perform_in).and_raise(RedisClient::CannotConnectError, "queue unavailable")

      expect { charge.handle_event_refund_updated!(event) }.to raise_error(RedisClient::CannotConnectError, "queue unavailable")

      expect(refund_rows.call.size).to eq(2)
      expect(purchases.map { _1.reload.stripe_refunded? }).to eq([true, true])
      expect(ErrorNotifier).to have_received(:notify).with(Charge::Refundable::EXTERNAL_REFUND_ALERT,
                                                           hash_including(recording_outcome: :unknown, error_class: "RedisClient::CannotConnectError"))
    end
  end

  it "captures the partial-refund mail arguments when the refund is booked" do
    purchase = create_purchase(10_00)
    stub_charge_refund(4_00)

    purchase.handle_event_refund_updated!(build_event(4_00))

    expect(buyer_mails(purchase).sole[:args][0..3]).to eq(["CustomerMailer", "partial_refund", "deliver_now",
                                                           { "args" => [purchase.email, purchase.link_id, purchase.id, 4_00, "partially", nil, nil],
                                                             "_aj_ruby2_keywords" => ["args"] }])
    expect(refund_webhooks(purchase).size).to eq(1)
  end

  it "keeps enqueueing inside the transaction for app-initiated refunds" do
    purchase = create_purchase(10_00)

    ApplicationRecord.transaction do
      purchase.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, -10_00), seller.id)
      expect(notification_counts([purchase])).to eq([[1, 1]])
      raise ActiveRecord::Rollback
    end

    expect(purchase.refunds.reload).to be_empty
  end
end
