# frozen_string_literal: true

require "spec_helper"

describe Refund do
  it "validates that processor_refund_id is unique"  do
    create(:refund, processor_refund_id: "ref_id")
    new_ref = build(:refund, processor_refund_id: "ref_id")
    expect(new_ref.valid?).to_not be(true)
  end

  describe "flags" do
    it "has an `is_for_fraud` flag" do
      flag_on = create(:refund, is_for_fraud: true)
      flag_off = create(:refund, is_for_fraud: false)

      expect(flag_on.is_for_fraud).to be true
      expect(flag_off.is_for_fraud).to be false
    end
  end

  it "sets the product and the seller of the purchase" do
    refund = create(:refund)
    expect(refund.product).to eq(refund.purchase.link)
    expect(refund.seller).to eq(refund.purchase.seller)
  end

  describe ".effective and #effective?" do
    it "counts completed, pending, and legacy NULL-status refunds" do
      completed = create(:refund, status: "succeeded")
      pending = create(:refund, status: "pending")
      legacy = create(:refund, status: nil)

      expect(Refund.effective).to include(completed, pending, legacy)
      expect([completed, pending, legacy].map(&:effective?)).to all(be true)
    end

    it "keeps counting a failed refund whose balance debits were NOT reversed" do
      # Non-reversed failures (external funds, dispute, legacy rows) still have the
      # seller debited, so they must stay in the refunded sums — otherwise the amount
      # would look refundable while stripe_refunded still blocks the admin action.
      failed_not_reversed = create(:refund, status: "failed")

      expect(Refund.effective).to include(failed_not_reversed)
      expect(failed_not_reversed.effective?).to be true
    end

    it "stops counting a failed refund once its balance debits were reversed" do
      failed_reversed = create(:refund, status: "failed")
      failed_reversed.balance_reversed_on_failure = true
      failed_reversed.save!

      expect(Refund.effective).not_to include(failed_reversed)
      expect(failed_reversed.effective?).to be false
    end

    it "treats a canceled refund exactly like a failed one" do
      # Stripe documents canceled as a terminal refund status (canceling a pending
      # refund returns the money to the platform balance) — the buyer never received
      # the money, so once reversed it must drop out of the refunded sums just like
      # a failed refund.
      canceled_not_reversed = create(:refund, status: "canceled")
      canceled_reversed = create(:refund, status: "canceled")
      canceled_reversed.balance_reversed_on_failure = true
      canceled_reversed.save!

      expect(Refund.effective).to include(canceled_not_reversed)
      expect(canceled_not_reversed.effective?).to be true
      expect(Refund.effective).not_to include(canceled_reversed)
      expect(canceled_reversed.effective?).to be false
      expect(Refund.reversed_failures).to include(canceled_reversed)
      expect(Refund.reversed_failures).not_to include(canceled_not_reversed)
    end
  end

  describe "#terminally_failed?" do
    it "is true for failed and canceled, false otherwise" do
      expect(build(:refund, status: "failed").terminally_failed?).to be true
      expect(build(:refund, status: "canceled").terminally_failed?).to be true
      expect(build(:refund, status: "succeeded").terminally_failed?).to be false
      expect(build(:refund, status: "pending").terminally_failed?).to be false
      expect(build(:refund, status: nil).terminally_failed?).to be false
    end
  end
end
