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

      refund.reload
      expect(refund.status).to eq("PENDING")
      expect(refund.paypal_refund_unreadable_at).to be_blank
    end

    it "retries notification after a notifier failure without marking the refund unreadable" do
      allow(PaypalChargeProcessor).to receive(:fetch_refund_status)
        .and_raise(ChargeProcessorError, "401|closed_user")
      allow(ErrorNotifier).to receive(:notify).and_raise(StandardError, "sentry unavailable")

      described_class.new.perform

      refund.reload
      expect(refund.status).to eq("PENDING")
      expect(refund.paypal_refund_unreadable_at).to be_blank
      expect(refund.json_data["paypal_refund_unreadable_issue"]).to be_nil
      expect(ErrorNotifier).to have_received(:notify).twice

      allow(ErrorNotifier).to receive(:notify).and_return(nil)
      described_class.new.perform

      expect(refund.reload.paypal_refund_unreadable_at).to be_present
      expect(refund.json_data["paypal_refund_unreadable_issue"]).to eq("closed_user")
      expect(ErrorNotifier).to have_received(:notify).exactly(3).times
    end

    it "does not let a persistent notifier outage abort later refunds" do
      sibling = create(:refund,
                       purchase:,
                       amount_cents: 0,
                       total_transaction_cents: 15_00,
                       status: "PENDING",
                       processor_refund_id: "8SL48586NM399494P",
                       created_at: 4.days.ago)
      allow(PaypalChargeProcessor).to receive(:fetch_refund_status) do |processor_refund_id:, **|
        raise ChargeProcessorError, "401|closed_user" if processor_refund_id == refund.processor_refund_id

        "FAILED"
      end
      allow(ErrorNotifier).to receive(:notify).and_raise(StandardError, "sentry unavailable")

      described_class.new.perform

      expect(refund.reload.status).to eq("PENDING")
      expect(refund.paypal_refund_unreadable_at).to be_blank
      expect(refund.paypal_refund_unreadable_issue).to be_nil
      expect(ErrorNotifier).to have_received(:notify).twice
      expect(sibling.reload.status).to eq("failed")
      expect(FailedRefundException.find_by(refund: sibling)).to be_present
    end

    it "notifies once then skips later passes for a closed PayPal merchant" do
      expect(PaypalChargeProcessor).to receive(:fetch_refund_status).once
        .and_raise(ChargeProcessorError, "401|closed_user")
      expect(ErrorNotifier).to receive(:notify).once.with(
        kind_of(ChargeProcessorError),
        context: hash_including(refund_id: refund.id, paypal_refund_unreadable: true)
      )

      described_class.new.perform
      described_class.new.perform

      refund.reload
      expect(refund.status).to eq("PENDING")
      expect(refund.paypal_refund_unreadable_at).to be_present
      expect(FailedRefundException.find_by(refund:)).to be_nil
    end

    %w(locked_user NOT_AUTHORIZED PERMISSION_DENIED).each do |issue|
      it "keeps reading #{issue} while deduplicating notifications" do
        expect(PaypalChargeProcessor).to receive(:fetch_refund_status).twice
          .and_raise(ChargeProcessorError, "403|#{issue}")
        expect(ErrorNotifier).to receive(:notify).once

        2.times { described_class.new.perform }

        expect(refund.reload.status).to eq("PENDING")
        expect(refund.paypal_refund_unreadable_at).to be_present
        expect(refund.json_data["paypal_refund_unreadable_issue"]).to eq(issue.downcase)
      end

      %w(COMPLETED FAILED).each do |status|
        it "recovers #{status} after #{issue} access is restored for the original merchant" do
          merchant_account.update!(deleted_at: Time.current)
          create(:merchant_account_paypal, user: seller)
          reads = 0
          expect(PaypalChargeProcessor).to receive(:fetch_refund_status).twice
            .with(processor_refund_id: refund.processor_refund_id, merchant_account:) do
              reads += 1
              raise ChargeProcessorInvalidRequestError.new("403|#<OpenStruct name=\"#{issue}\">", processor_error_code: issue) if reads == 1
              status
            end
          expect(ErrorNotifier).to receive(:notify).once

          2.times { described_class.new.perform }

          expect(refund.reload.status).to eq(status == "FAILED" ? "failed" : status)
          expect(FailedRefundException.exists?(refund:)).to eq(status == "FAILED")
          expect(refund.balance_reversed_on_failure).to be_falsey
        end
      end
    end

    %w(COMPLETED FAILED).each do |status|
      it "recovers #{status} for an unclassified legacy timestamp marker" do
        refund.update!(paypal_refund_unreadable_at: 1.hour.ago.iso8601)
        expect(PaypalChargeProcessor).to receive(:fetch_refund_status).and_return(status)
        expect(ErrorNotifier).not_to receive(:notify)

        described_class.new.perform

        expect(refund.reload.status).to eq(status == "FAILED" ? "failed" : status)
        expect(FailedRefundException.exists?(refund:)).to eq(status == "FAILED")
      end
    end

    it "classifies a previously notified error as closed without sending another alert" do
      refund.update!(paypal_refund_unreadable_at: 1.hour.ago.iso8601)
      expect(PaypalChargeProcessor).to receive(:fetch_refund_status).once
        .and_raise(ChargeProcessorError, "401|closed_user")
      expect(ErrorNotifier).not_to receive(:notify)

      2.times { described_class.new.perform }

      expect(refund.reload.json_data["paypal_refund_unreadable_issue"]).to eq("closed_user")
    end

    [nil, ""].each do |timestamp|
      it "reads an explicitly closed marker with a #{timestamp.inspect} notification timestamp" do
        refund.update!(json_data: { paypal_refund_unreadable_issue: "closed_user", paypal_refund_unreadable_at: timestamp })
        expect(PaypalChargeProcessor).to receive(:fetch_refund_status).and_return("COMPLETED")

        described_class.new.perform

        expect(refund.reload.status).to eq("COMPLETED")
      end
    end

    it "skips later reads after a structured closed_user response" do
      error = ChargeProcessorInvalidRequestError.new('403|#<OpenStruct name="NOT_AUTHORIZED", details=[#<OpenStruct issue="CLOSED_USER">]>',
                                                     processor_error_code: "CLOSED_USER")
      expect(PaypalChargeProcessor).to receive(:fetch_refund_status).once.and_raise(error)
      expect(ErrorNotifier).to receive(:notify).once

      2.times { described_class.new.perform }

      expect(refund.reload.paypal_refund_unreadable_issue).to eq("closed_user")
    end

    it "rechecks pending status after a read fails" do
      allow(PaypalChargeProcessor).to receive(:fetch_refund_status) do
        Refund.find(refund.id).update!(status: "COMPLETED")
        raise ChargeProcessorError, "401|closed_user"
      end
      expect(ErrorNotifier).not_to receive(:notify)

      described_class.new.perform

      expect(refund.reload.status).to eq("COMPLETED")
      expect(refund.paypal_refund_unreadable_at).to be_nil
    end

    ["403|a message mentioning closed_user", '403|#<OpenStruct name="OTHER", message="closed_user">',
     '403|#<OpenStruct name="OTHER", message="issue=\\"closed_user\\"">'].each do |message|
      it "does not classify an unrelated message as closed: #{message}" do
        expect(PaypalChargeProcessor).to receive(:fetch_refund_status).twice
          .and_raise(ChargeProcessorError, message)
        expect(ErrorNotifier).to receive(:notify).twice.with(
          kind_of(ChargeProcessorError), context: { refund_id: refund.id, purchase_id: purchase.id }
        )

        2.times { described_class.new.perform }

        expect(refund.reload.paypal_refund_unreadable_at).to be_nil
      end
    end

    %w(closed_user locked_user NOT_AUTHORIZED PERMISSION_DENIED).each do |issue|
      it "does not move money or alter the purchase on #{issue}" do
        allow(PaypalChargeProcessor).to receive(:fetch_refund_status)
          .and_raise(ChargeProcessorError, "403|#{issue}")
        allow(ErrorNotifier).to receive(:notify)
        expect(ChargeProcessor).not_to receive(:refund!)
        expect(PaypalChargeProcessor).not_to receive(:refund!)
        expect(Purchase::HandleFailedRefundService).not_to receive(:new)
        balance = create(:balance, user: seller, merchant_account:)
        payment = create(:payment, user: seller)
        balance_before = balance.attributes
        payment_before = payment.attributes
        purchase_before = purchase.reload.attributes
        money_before = [Balance, BalanceTransaction, Credit, Payment, Refund, FailedRefundException].map(&:count)

        described_class.new.perform

        expect(purchase.reload.attributes).to eq(purchase_before)
        expect(balance.reload.attributes).to eq(balance_before)
        expect(payment.reload.attributes).to eq(payment_before)
        expect([Balance, BalanceTransaction, Credit, Payment, Refund, FailedRefundException].map(&:count)).to eq(money_before)
        expect(refund.reload.status).to eq("PENDING")
        expect(refund.balance_reversed_on_failure).to be_falsey
      end
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
