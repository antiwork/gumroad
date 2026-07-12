# frozen_string_literal: true

require "spec_helper"

describe RefundPurchaseWorker do
  describe "#perform" do
    let(:admin_user) { create(:admin_user) }
    let(:purchase) { create(:purchase) }
    let(:purchase_double) { double }

    before do
      expect(Purchase).to receive(:find).with(purchase.id).and_return(purchase_double)
    end

    context "when the reason is `Refund::FRAUD`" do
      it "calls #refund_for_fraud_and_block_buyer! on the purchase" do
        expect(purchase_double).to receive(:refund_for_fraud_and_block_buyer!).with(admin_user.id)

        described_class.new.perform(purchase.id, admin_user.id, Refund::FRAUD)
      end
    end

    context "when the reason is not supplied" do
      it "calls #refund_and_save! on the purchase with no reason" do
        expect(purchase_double).to receive(:refund_and_save!).with(admin_user.id, reason: nil)

        described_class.new.perform(purchase.id, admin_user.id)
      end
    end

    context "when a free-text reason is supplied" do
      it "passes the reason through to #refund_and_save!" do
        expect(purchase_double).to receive(:refund_and_save!).with(admin_user.id, reason: "Buyer was charged twice")

        described_class.new.perform(purchase.id, admin_user.id, "Buyer was charged twice")
      end
    end
  end
end
