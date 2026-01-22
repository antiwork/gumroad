# frozen_string_literal: true

require "spec_helper"

describe MassRefundForFraudJob do
  let(:admin_user) { create(:admin_user) }
  let(:product) { create(:product) }

  describe "#perform" do
    let(:purchase1) { instance_double(Purchase, external_id: "ext-1", link_id: product.id) }
    let(:purchase2) { instance_double(Purchase, external_id: "ext-2", link_id: product.id) }
    let(:external_ids) { [purchase1.external_id, purchase2.external_id] }

    before do
      allow(Purchase).to receive(:find_by_external_id).with(purchase1.external_id).and_return(purchase1)
      allow(Purchase).to receive(:find_by_external_id).with(purchase2.external_id).and_return(purchase2)
    end

    it "processes each purchase and logs results" do
      expect(purchase1).to receive(:refund_for_fraud_and_block_buyer!).with(admin_user.id)
      expect(purchase2).to receive(:refund_for_fraud_and_block_buyer!).with(admin_user.id)

      expect(Rails.logger).to receive(:info).with(/Mass fraud refund completed for product #{product.id}: 2 succeeded, 0 failed/)

      described_class.new.perform(product.id, external_ids, admin_user.id)
    end

    it "handles missing purchases gracefully" do
      missing_external_id = "nonexistent"
      external_ids_with_missing = [purchase1.external_id, missing_external_id]

      expect(purchase1).to receive(:refund_for_fraud_and_block_buyer!).with(admin_user.id)

      allow(Purchase).to receive(:find_by_external_id).with(missing_external_id).and_return(nil)

      expect(Rails.logger).to receive(:info).with(/Mass fraud refund completed for product #{product.id}: 1 succeeded, 1 failed/)

      described_class.new.perform(product.id, external_ids_with_missing, admin_user.id)
    end

    it "handles refund errors and continues processing" do
      expect(purchase1).to receive(:refund_for_fraud_and_block_buyer!).with(admin_user.id).and_raise(StandardError.new("Refund failed"))
      expect(purchase2).to receive(:refund_for_fraud_and_block_buyer!).with(admin_user.id)

      expect(Bugsnag).to receive(:notify).with(instance_of(StandardError))
      expect(Rails.logger).to receive(:info).with(/Mass fraud refund completed for product #{product.id}: 1 succeeded, 1 failed/)

      described_class.new.perform(product.id, external_ids, admin_user.id)
    end
  end
end
