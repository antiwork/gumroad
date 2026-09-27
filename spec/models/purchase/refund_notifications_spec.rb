# frozen_string_literal: true

require "spec_helper"

# Commit callbacks must see a real commit or rollback, so this file runs outside the fixture
# transaction and deletes the rows it inserted.
describe Purchase, "refund notifications" do
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
  let!(:purchase) do
    create(:purchase_with_balance, link: create(:product, user: seller, price_cents: 10_00), seller:, merchant_account:,
                                   price_cents: 10_00, total_transaction_cents: 10_00)
  end

  before { allow(ErrorNotifier).to receive(:notify) }

  def flow_of_funds(cents) = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, -cents)

  def refund_webhooks
    PostToPingEndpointsWorker.jobs.select { _1["args"][0] == purchase.id && _1["args"][2] == ResourceSubscription::REFUNDED_RESOURCE_NAME }
  end

  def buyer_mails
    ActiveJob::Base.queue_adapter.enqueued_jobs.select do |job|
      arguments = job[:args]
      arguments[0] == "CustomerMailer" && %w[refund partial_refund].include?(arguments[1]) && arguments.dig(3, "args", 2) == purchase.id
    end
  end

  def notification_counts = [refund_webhooks.size, buyer_mails.size]

  context "when deferred until commit" do
    it "enqueues the webhook and the buyer mail once, after the transaction commits" do
      counts_inside_transaction = ApplicationRecord.transaction do
        purchase.refund_purchase!(flow_of_funds(10_00), seller.id, nil, false, defer_notifications_until_commit: true)
        notification_counts
      end

      expect(counts_inside_transaction).to eq([0, 0])
      expect(notification_counts).to eq([1, 1])
      expect(refund_webhooks.sole["args"]).to eq([purchase.id, nil, ResourceSubscription::REFUNDED_RESOURCE_NAME])
      expect(buyer_mails.sole[:args][0..3]).to eq(["CustomerMailer", "refund", "deliver_now",
                                                   { "args" => [purchase.email, purchase.link_id, purchase.id], "_aj_ruby2_keywords" => ["args"] }])
    end

    it "enqueues nothing when the transaction rolls back" do
      ApplicationRecord.transaction do
        purchase.refund_purchase!(flow_of_funds(10_00), seller.id, nil, false, defer_notifications_until_commit: true)
        raise ActiveRecord::Rollback
      end

      expect(purchase.refunds.reload).to be_empty
      expect(notification_counts).to eq([0, 0])
    end

    it "captures the partial-refund mail arguments when the refund is booked" do
      purchase.refund_purchase!(flow_of_funds(4_00), seller.id, nil, false, defer_notifications_until_commit: true)

      expect(buyer_mails.sole[:args][0..3]).to eq(["CustomerMailer", "partial_refund", "deliver_now",
                                                   { "args" => [purchase.email, purchase.link_id, purchase.id, 4_00, "partially", nil, nil],
                                                     "_aj_ruby2_keywords" => ["args"] }])
      expect(refund_webhooks.size).to eq(1)
    end

    it "alerts and still enqueues the buyer mail when the webhook enqueue fails after commit" do
      allow(PostToPingEndpointsWorker).to receive(:perform_in).and_raise(RedisClient::CannotConnectError, "queue unavailable")

      expect do
        purchase.refund_purchase!(flow_of_funds(10_00), seller.id, nil, false, defer_notifications_until_commit: true)
      end.not_to raise_error

      expect(purchase.reload.stripe_refunded?).to be(true)
      expect(buyer_mails.size).to eq(1)
      expect(ErrorNotifier).to have_received(:notify).with(
        Purchase::Refundable::REFUND_NOTIFICATION_FAILED_ALERT,
        purchase_id: purchase.id, notification: :webhook, error_class: "RedisClient::CannotConnectError"
      )
    end

    it "logs the missed notification when the alert itself fails" do
      allow(PostToPingEndpointsWorker).to receive(:perform_in).and_raise(RedisClient::CannotConnectError, "queue unavailable")
      allow(ErrorNotifier).to receive(:notify).and_raise("notifier down")
      allow(Rails.logger).to receive(:warn)

      expect do
        purchase.refund_purchase!(flow_of_funds(10_00), seller.id, nil, false, defer_notifications_until_commit: true)
      end.not_to raise_error

      expect(buyer_mails.size).to eq(1)
      expect(Rails.logger).to have_received(:warn).with(
        a_string_including("Refund notification alert failed", "RuntimeError: notifier down", "purchase_id: #{purchase.id}",
                           "notification: webhook", "error_class: RedisClient::CannotConnectError")
      )
    end
  end

  context "when not deferred" do
    it "enqueues inside the transaction" do
      ApplicationRecord.transaction do
        purchase.refund_purchase!(flow_of_funds(10_00), seller.id)
        expect(notification_counts).to eq([1, 1])
        raise ActiveRecord::Rollback
      end

      expect(purchase.refunds.reload).to be_empty
    end

    it "raises an enqueue failure and records nothing" do
      allow(PostToPingEndpointsWorker).to receive(:perform_in).and_raise(RedisClient::CannotConnectError, "queue unavailable")

      expect do
        purchase.refund_purchase!(flow_of_funds(10_00), seller.id)
      end.to raise_error(RedisClient::CannotConnectError, "queue unavailable")

      expect(purchase.refunds.reload).to be_empty
    end
  end

  it "defers the notifications of a refund the Stripe webhook books" do
    purchase.update!(stripe_transaction_id: "ch_notify_#{SecureRandom.hex(6)}")
    charge_refund = ChargeRefund.new
    charge_refund.id = "re_notify_#{SecureRandom.hex(6)}"
    charge_refund.charge_processor_id = StripeChargeProcessor.charge_processor_id
    charge_refund.flow_of_funds = flow_of_funds(10_00)
    charge_refund.instance_variable_set(:@refund, Stripe::StripeObject.construct_from(id: charge_refund.id, status: "succeeded"))
    allow_any_instance_of(StripeChargeProcessor).to receive(:get_refund).and_return(charge_refund)
    counts_inside_transaction = nil
    allow_any_instance_of(Purchase).to receive(:update_creator_analytics_cache).and_wrap_original do |method, *args, **kwargs|
      counts_inside_transaction = notification_counts if ApplicationRecord.connection.transaction_open?
      method.call(*args, **kwargs)
    end
    event = ChargeEvent.new.tap do |charge_event|
      charge_event.charge_id = purchase.stripe_transaction_id
      charge_event.refund_id = charge_refund.id
      charge_event.extras = { refund_status: "succeeded", refunded_amount_cents: 10_00, refund_reason: nil }
    end

    purchase.handle_event_refund_updated!(event)

    expect(counts_inside_transaction).to eq([0, 0])
    expect(notification_counts).to eq([1, 1])
  end
end
