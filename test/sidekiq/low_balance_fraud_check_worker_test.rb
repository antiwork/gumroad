# frozen_string_literal: true

require "test_helper"

class LowBalanceFraudCheckWorkerTest < ActiveSupport::TestCase
  self.described_class = LowBalanceFraudCheckWorker


  context_ LowBalanceFraudCheckWorker do
  context_ "#perform" do
      before do
        @purchase = create(:purchase)
      end

  test "invokes .check_for_low_balance_and_probate for the seller" do
        expect_any_instance_of(User).to receive(:check_for_low_balance_and_probate)

        described_class.new.perform(@purchase.id)
      end
    end
  end
end
