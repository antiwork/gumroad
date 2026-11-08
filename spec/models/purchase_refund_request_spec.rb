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
  end

  describe "closing on refund" do
    it "marks the open request refunded when the purchase is refunded" do
      request = create(:purchase_refund_request, purchase:)

      purchase.update!(stripe_refunded: true)

      expect(request.reload.state).to eq("refunded")
    end

    it "does not touch already-closed requests" do
      request = create(:purchase_refund_request, purchase:, state: "declined")

      purchase.update!(stripe_refunded: true)

      expect(request.reload.state).to eq("declined")
    end
  end
end
