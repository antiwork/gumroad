# frozen_string_literal: true

require "test_helper"

class RefundPurchaseWorkerTest < ActiveSupport::TestCase
  self.described_class = RefundPurchaseWorker



  context_ RefundPurchaseWorker do
  context_ "#perform" do
      let(:admin_user) { create(:admin_user) }
      let(:purchase) { create(:purchase) }
      let(:purchase_double) { double }

      before do
        expect(Purchase).to receive(:find).with(purchase.id).and_return(purchase_double)
      end

  context_ "when the reason is `Refund::FRAUD`" do
  test "calls #refund_for_fraud_and_block_buyer! on the purchase" do
          expect(purchase_double).to receive(:refund_for_fraud_and_block_buyer!).with(admin_user.id)

          described_class.new.perform(purchase.id, admin_user.id, Refund::FRAUD)
        end
      end

  context_ "when the reason is not supplied" do
  test "calls #refund_and_save! on the purchase" do
          expect(purchase_double).to receive(:refund_and_save!).with(admin_user.id)

          described_class.new.perform(purchase.id, admin_user.id)
        end
      end
    end
  end
end
