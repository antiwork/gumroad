# frozen_string_literal: true

describe EnforceRefundPolicyForSellerJob do
  describe "#perform" do
    it "runs the dispute-rate refund-policy enforcement check for the purchase" do
      purchase = create(:purchase)

      expect_any_instance_of(Purchase).to receive(:enforce_refund_policy_for_seller_based_on_dispute_rate!)

      described_class.new.perform(purchase.id)
    end
  end
end
