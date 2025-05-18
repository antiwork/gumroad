# frozen_string_literal: true

describe LowBalanceFraudCheckWorker do
  describe "#perform" do
    before do
      @purchase = create(:purchase)
    end

    it "invokes .check_for_low_balance_and_probate for the seller" do
      expect_any_instance_of(User).to receive(:check_for_low_balance_and_probate)

      described_class.new.perform(@purchase.id)
    end
  end
end
