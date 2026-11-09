# frozen_string_literal: true

require "spec_helper"

describe PurchaseRefundRequest do
  let(:purchase) { create(:purchase) }

  describe "validations" do
    it "caps the message length" do
      request = build(:purchase_refund_request, purchase:, message: "a" * (described_class::MAX_MESSAGE_LENGTH + 1))
      expect(request).not_to be_valid
      expect(request.errors[:message]).to be_present
    end

    it "rejects unknown reasons" do
      request = build(:purchase_refund_request, purchase:, reason: "because")
      expect(request).not_to be_valid
    end
  end

  describe "one open request per purchase" do
    it "refuses a second open request at the database" do
      create(:purchase_refund_request, purchase:)

      expect do
        # Bypass validations to prove the DATABASE enforces it, not just app code.
        build(:purchase_refund_request, purchase:).save!(validate: false)
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "allows a new request after the previous one closed" do
      create(:purchase_refund_request, purchase:, state: "declined")

      expect(create(:purchase_refund_request, purchase:)).to be_persisted
    end
  end

  describe "#sync_open_key" do
    it "holds the purchase id while open and clears it on close" do
      request = create(:purchase_refund_request, purchase:)
      expect(request.open_key).to eq(purchase.id)

      request.update!(state: "seen")
      expect(request.open_key).to eq(purchase.id)

      request.update!(state: "refunded")
      expect(request.open_key).to be_nil
    end
  end

  describe "state transition logging" do
    it "logs creation and each state change with the stable prefix" do
      expect(Rails.logger).to receive(:info).with(a_string_starting_with("[PurchaseRefundRequest]")).twice.and_call_original

      request = create(:purchase_refund_request, purchase:)
      request.update!(state: "refunded")
    end

    it "never logs the buyer's free-text message" do
      logged = []
      allow(Rails.logger).to receive(:info) { |line| logged << line.to_s }

      create(:purchase_refund_request, purchase:, message: "SECRET-BUYER-TEXT")

      expect(logged.join).not_to include("SECRET-BUYER-TEXT")
    end
  end

  describe "#escalation_deadline" do
    it "adds two business days, skipping weekends" do
      request = create(:purchase_refund_request, purchase:)
      request.update_column(:created_at, Time.utc(2026, 11, 6, 12)) # Friday

      expect(request.reload.escalation_deadline.to_date).to eq(Date.new(2026, 11, 10)) # Tuesday
    end
  end

  describe "notification enqueueing" do
    it "enqueues the notify job on create" do
      request = create(:purchase_refund_request, purchase:)

      expect(PurchaseRefundRequests::NotifyJob.jobs.map { |job| job["args"] }).to eq([[request.id]])
    end

    it "does not re-enqueue on state changes" do
      request = create(:purchase_refund_request, purchase:)
      PurchaseRefundRequests::NotifyJob.jobs.clear

      request.update!(state: "seen")

      expect(PurchaseRefundRequests::NotifyJob.jobs.size).to eq(0)
    end
  end

  describe "#notifications_pending?" do
    it "is true while a stamp is missing on an open request, false otherwise" do
      request = create(:purchase_refund_request, purchase:)
      expect(request.notifications_pending?).to eq(true)

      request.update_columns(seller_notified_at: Time.current, support_notified_at: Time.current)
      expect(request.reload.notifications_pending?).to eq(false)

      request.update_columns(support_notified_at: nil, state: "declined")
      expect(request.reload.notifications_pending?).to eq(false)
    end
  end

  describe ".purchase_eligible?" do
    it "accepts a completed paid purchase" do
      expect(described_class.purchase_eligible?(purchase)).to eq(true)
    end

    it "rejects a refunded purchase" do
      purchase.update!(stripe_refunded: true)
      expect(described_class.purchase_eligible?(purchase)).to eq(false)
    end

    it "rejects a partially refunded purchase" do
      purchase.update!(stripe_partially_refunded: true)
      expect(described_class.purchase_eligible?(purchase)).to eq(false)
    end

    it "rejects a charged-back purchase" do
      purchase.update!(chargeback_date: Time.current)
      expect(described_class.purchase_eligible?(purchase)).to eq(false)
    end

    it "rejects a free purchase" do
      free_purchase = create(:purchase, link: create(:product, price_range: "0+"), price_cents: 0,
                                        stripe_transaction_id: nil, stripe_fingerprint: nil)
      expect(described_class.purchase_eligible?(free_purchase)).to eq(false)
    end

    it "rejects a failed purchase" do
      purchase.update_column(:purchase_state, "failed")
      expect(described_class.purchase_eligible?(purchase.reload)).to eq(false)
    end

    it "rejects a purchase outside the seller's refund window" do
      create(:purchase_refund_policy, purchase:, max_refund_period_in_days: 7)
      purchase.update!(created_at: 8.days.ago)
      expect(described_class.purchase_eligible?(purchase)).to eq(false)
    end

    it "accepts a purchase inside the seller's refund window" do
      create(:purchase_refund_policy, purchase:, max_refund_period_in_days: 7)
      purchase.update!(created_at: 6.days.ago)
      expect(described_class.purchase_eligible?(purchase)).to eq(true)
    end

    it "rejects a purchase under a no-refunds policy" do
      create(:purchase_refund_policy, purchase:, title: "No refunds allowed", max_refund_period_in_days: 0)
      expect(described_class.purchase_eligible?(purchase)).to eq(false)
    end

    it "rejects a purchase whose previous request was declined or expired" do
      create(:purchase_refund_request, purchase:, state: "declined")
      expect(described_class.purchase_eligible?(purchase)).to eq(false)
    end

    it "rejects a purchase whose previous request was escalated to support" do
      create(:purchase_refund_request, purchase:, state: "escalated")
      expect(described_class.purchase_eligible?(purchase)).to eq(false)
    end

    it "applies the original purchase's no-refunds policy to a subscription renewal" do
      original = create(:membership_purchase)
      create(:purchase_refund_policy, purchase: original, title: "No refunds allowed", max_refund_period_in_days: 0)
      renewal = create(:purchase, link: original.link, subscription: original.subscription, is_original_subscription_purchase: false, email: original.email, price_cents: 5_00)

      expect(renewal.purchase_refund_policy).to be_nil
      expect(described_class.purchase_eligible?(renewal)).to eq(false)
    end

    it "rejects a preorder authorization, which has not been charged" do
      expect(described_class.purchase_eligible?(create(:preorder_authorization_purchase, stripe_transaction_id: nil))).to eq(false)
    end
  end

  describe "closing on refund" do
    it "marks the open request refunded when the purchase is refunded" do
      request = create(:purchase_refund_request, purchase:)

      purchase.update!(stripe_refunded: true)

      expect(request.reload.state).to eq("refunded")
    end

    it "expires the open request when the purchase is charged back" do
      request = create(:purchase_refund_request, purchase:)

      purchase.update!(chargeback_date: Time.current)

      expect(request.reload.state).to eq("expired")
    end

    it "re-expires a refunded request when the refund is reversed" do
      request = create(:purchase_refund_request, purchase:)
      purchase.update!(stripe_refunded: true)
      expect(request.reload.state).to eq("refunded")

      purchase.update!(stripe_refunded: false)

      expect(request.reload.state).to eq("expired")
    end

    it "marks an escalated request refunded when the purchase is refunded after the deadline" do
      request = create(:purchase_refund_request, purchase:, state: "escalated")

      purchase.update!(stripe_refunded: true)

      expect(request.reload.state).to eq("refunded")
    end

    it "expires an escalated request when the purchase is charged back" do
      request = create(:purchase_refund_request, purchase:, state: "escalated")

      purchase.update!(chargeback_date: Time.current)

      expect(request.reload.state).to eq("expired")
    end

    it "does not touch already-closed requests" do
      request = create(:purchase_refund_request, purchase:, state: "declined")

      purchase.update!(stripe_refunded: true)

      expect(request.reload.state).to eq("declined")
    end

    it "marks the open request refunded when the seller refunds through refund_purchase!" do
      request = create(:purchase_refund_request, purchase:)

      purchase.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, purchase.total_transaction_cents), purchase.seller.id)

      expect(purchase.reload.stripe_refunded).to eq(true)
      expect(request.reload.state).to eq("refunded")
    end

    it "closes the request only after a caller's transaction around refund_purchase! commits" do
      request = create(:purchase_refund_request, purchase:)

      ActiveRecord::Base.transaction do
        purchase.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, purchase.total_transaction_cents), purchase.seller.id)
        expect(request.reload.state).to eq("requested")
      end

      expect(request.reload.state).to eq("refunded")
    end

    it "keeps the request open on a partial refund and closes it when the rest is refunded" do
      request = create(:purchase_refund_request, purchase:)
      half = purchase.total_transaction_cents / 2

      purchase.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, half), purchase.seller.id)
      expect(request.reload.state).to eq("requested")

      purchase.reload.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, purchase.total_transaction_cents - half), purchase.seller.id)
      expect(purchase.reload.stripe_refunded).to eq(true)
      expect(request.reload.state).to eq("refunded")
    end

    it "keeps the purchase's later after_commit callbacks working on a chargeback" do
      travel_to(Time.utc(2020, 1, 10))
      purchase = create(:purchase, created_at: 2.days.ago)
      request = create(:purchase_refund_request, purchase:)
      RegenerateCreatorAnalyticsCacheWorker.jobs.clear

      purchase.mark_as_disputed!(disputed_at: Time.current)

      expect(request.reload.state).to eq("expired")
      expect(RegenerateCreatorAnalyticsCacheWorker).to have_enqueued_sidekiq_job(purchase.seller_id, "2020-01-07")
    end
  end
end
