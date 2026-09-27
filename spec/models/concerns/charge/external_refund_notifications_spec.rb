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

  def creator_mails(purchases)
    ActiveJob::Base.queue_adapter.enqueued_jobs.select do |job|
      job[:args][0] == "ContactingCreatorMailer" && job[:args][1] == "purchase_refunded" &&
        purchases.map(&:id).include?(job.dig(:args, 3, "args", 0))
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

    it "alerts and still emails the creator when a deferred enqueue fails after commit" do
      allow(PostToPingEndpointsWorker).to receive(:perform_in).and_raise(RedisClient::CannotConnectError, "queue unavailable")

      expect { charge.handle_event_refund_updated!(event) }.not_to raise_error

      expect(refund_rows.call.size).to eq(2)
      expect(purchases.map { _1.reload.stripe_refunded? }).to eq([true, true])
      expect(ErrorNotifier).to have_received(:notify).with(Purchase::Refundable::REFUND_NOTIFICATION_FAILED_ALERT,
                                                           hash_including(notification: :webhook,
                                                                          error_class: "RedisClient::CannotConnectError")).twice
      expect(buyer_mails(purchases.first).size).to eq(1)
      expect(buyer_mails(purchases.last).size).to eq(1)
      expect(creator_mails(purchases).size).to eq(2)
    end

    it "still emails the creator when the deferred enqueue alert itself fails" do
      allow(PostToPingEndpointsWorker).to receive(:perform_in).and_raise(RedisClient::CannotConnectError, "queue unavailable")
      allow(Rails.logger).to receive(:warn)
      allow(ErrorNotifier).to receive(:notify).and_wrap_original do |method, *args, **kwargs|
        raise "notifier down" if kwargs[:notification]

        method.call(*args, **kwargs)
      end

      expect { charge.handle_event_refund_updated!(event) }.not_to raise_error

      expect(creator_mails(purchases).size).to eq(2)
      purchases.each do |purchase|
        expect(Rails.logger).to have_received(:warn).with(
          a_string_including(
            "Refund notification alert failed",
            "RuntimeError: notifier down",
            "purchase_id: #{purchase.id}",
            "notification: webhook",
            "error_class: RedisClient::CannotConnectError"
          )
        )
      end
    end

    it "still emails the creator and logs the refund report when the post-commit alert itself fails" do
      allow(Rails.logger).to receive(:warn)
      allow(ErrorNotifier).to receive(:notify).and_wrap_original do |method, *args, **kwargs|
        raise "notifier down" if args.first == Charge::Refundable::EXTERNAL_REFUND_ALERT

        method.call(*args, **kwargs)
      end

      expect { charge.handle_event_refund_updated!(event) }.not_to raise_error

      expect(creator_mails(purchases).size).to eq(2)
      expect(Rails.logger).to have_received(:warn).with(
        a_string_including(
          "External refund alert failed",
          "RuntimeError: notifier down",
          "message: #{Charge::Refundable::EXTERNAL_REFUND_ALERT.inspect}",
          "stripe_refund_id: #{refund_id.inspect}",
          "stripe_charge_id: #{event.charge_id.inspect}",
          "refunded_amount_cents: #{event.extras[:refunded_amount_cents].inspect}",
          "transfer_outcome: nil",
          "refunded_purchase_ids: #{purchases.map(&:id).sort.inspect}",
          "unrecorded_purchase_ids: []",
          "blocked_purchase_ids: []",
          "recorded: true"
        )
      )
    end
  end
end
