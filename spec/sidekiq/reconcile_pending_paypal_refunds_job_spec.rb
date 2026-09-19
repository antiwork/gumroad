# frozen_string_literal: true

require "spec_helper"

describe ReconcilePendingPaypalRefundsJob do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 15_00) }
  let(:merchant_account) { create(:merchant_account_paypal, user: seller) }
  let(:purchase) do
    create(:purchase,
           link: product,
           seller:,
           merchant_account:,
           charge_processor_id: PaypalChargeProcessor.charge_processor_id,
           price_cents: 15_00,
           total_transaction_cents: 15_00)
  end
  let(:refund) do
    create(:refund,
           purchase:,
           amount_cents: 15_00,
           total_transaction_cents: 15_00,
           status: "PENDING",
           processor_refund_id: "64J80824NV272645E",
           created_at: 5.days.ago)
  end

  def processor_reports(status)
    allow(PaypalChargeProcessor).to receive(:fetch_refund_status).and_return(status)
  end

  describe "#perform" do
    # The refund must exist before #perform runs; `refund` is a lazy let otherwise.
    before { refund }

    it "handles a refund PayPal reports as failed through HandleFailedRefundService" do
      processor_reports("FAILED")

      described_class.new.perform

      expect(refund.reload.status).to eq("failed")
      exception = FailedRefundException.find_by(refund:)
      expect(exception).to be_present
      expect(exception.state).to eq("pending")
      expect(exception.owner).to eq(FailedRefundException.default_owner)
    end

    it "keeps PayPal's canceled terminal status mapping for a refund PayPal cancels" do
      processor_reports("CANCELLED")

      described_class.new.perform

      expect(refund.reload.status).to eq("canceled")
      expect(FailedRefundException.find_by(refund:)).to be_present
    end

    it "backfills the status of a refund PayPal reports as completed without queueing it" do
      processor_reports("COMPLETED")

      described_class.new.perform

      expect(refund.reload.status).to eq("COMPLETED")
      expect(FailedRefundException.find_by(refund:)).to be_nil
    end

    it "leaves a refund PayPal still reports as pending untouched" do
      processor_reports("PENDING")

      described_class.new.perform

      expect(refund.reload.status).to eq("PENDING")
      expect(FailedRefundException.find_by(refund:)).to be_nil
    end

    it "handles a processor status that is not upper-cased" do
      refund.update!(status: "pending")
      processor_reports("failed")

      described_class.new.perform

      expect(refund.reload.status).to eq("failed")
      expect(FailedRefundException.find_by(refund:)).to be_present
    end

    it "reads the processor with the refund id and the seller's merchant account" do
      expect(PaypalChargeProcessor).to receive(:fetch_refund_status)
        .with(processor_refund_id: "64J80824NV272645E", merchant_account:)

      described_class.new.perform
    end

    it "reports a failed read and leaves the refund for the next run" do
      allow(PaypalChargeProcessor).to receive(:fetch_refund_status)
        .and_raise(ChargeProcessorError, "404|Resource not found")
      expect(ErrorNotifier).to receive(:notify).with(kind_of(ChargeProcessorError), context: hash_including(refund_id: refund.id))

      described_class.new.perform

      expect(refund.reload.status).to eq("PENDING")
    end

    it "does not let one unreadable refund stop the others" do
      sibling = create(:refund,
                       purchase:,
                       amount_cents: 0,
                       total_transaction_cents: 15_00,
                       status: "PENDING",
                       processor_refund_id: "8SL48586NM399494P",
                       created_at: 4.days.ago)
      allow(PaypalChargeProcessor).to receive(:fetch_refund_status) do |processor_refund_id:, **|
        raise ChargeProcessorError, "404|Resource not found" if processor_refund_id == refund.processor_refund_id

        "FAILED"
      end
      allow(ErrorNotifier).to receive(:notify)

      described_class.new.perform

      expect(refund.reload.status).to eq("PENDING")
      expect(sibling.reload.status).to eq("failed")
    end

    context "when a refund is outside the reconciliation window" do
      it "skips refunds younger than the minimum age" do
        refund.update!(created_at: 1.day.ago)
        expect(PaypalChargeProcessor).not_to receive(:fetch_refund_status)

        described_class.new.perform
      end
    end

    it "skips refunds that are not PayPal's" do
      stripe_purchase = create(:purchase, link: product, seller:,
                                          merchant_account: create(:merchant_account, user: seller),
                                          price_cents: 15_00, total_transaction_cents: 15_00)
      create(:refund,
             purchase: stripe_purchase,
             amount_cents: 15_00,
             total_transaction_cents: 15_00,
             status: "PENDING",
             processor_refund_id: "re_stripe_test",
             created_at: 5.days.ago)
      expect(PaypalChargeProcessor).to receive(:fetch_refund_status)
        .with(processor_refund_id: "64J80824NV272645E", merchant_account:).once.and_return("PENDING")

      described_class.new.perform
    end

    it "skips a refund we never recorded a processor refund id for" do
      refund.update!(processor_refund_id: nil)
      expect(PaypalChargeProcessor).not_to receive(:fetch_refund_status)

      described_class.new.perform
    end
  end
end
