# frozen_string_literal: true

require "test_helper"

class ProcessPaymentWorkerTest < ActiveSupport::TestCase
  self.described_class = ProcessPaymentWorker


  context_ ProcessPaymentWorker do
  context_ "#perform" do
  test "does nothing if the payment is not in processing state" do
        expect(StripePayoutProcessor).not_to receive(:process_payments)

        ProcessPaymentWorker.new.perform(create(:payment, state: "creating").id)
        ProcessPaymentWorker.new.perform(create(:payment, state: "unclaimed").id)
        ProcessPaymentWorker.new.perform(create(:payment, state: "failed").id)
        ProcessPaymentWorker.new.perform(create(:payment, state: "completed", txn_id: "dummy", processor_fee_cents: 1).id)
        ProcessPaymentWorker.new.perform(create(:payment, state: "reversed").id)
        ProcessPaymentWorker.new.perform(create(:payment, state: "returned").id)
        ProcessPaymentWorker.new.perform(create(:payment, state: "cancelled").id)
      end

  test "processes the payment if it is in processing state" do
        payment = create(:payment, processor: "STRIPE", state: "processing")

        expect(StripePayoutProcessor).to receive(:process_payments).with([payment])

        ProcessPaymentWorker.new.perform(payment.id)
      end
    end
  end
end
