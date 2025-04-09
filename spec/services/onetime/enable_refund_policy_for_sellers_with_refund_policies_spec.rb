# frozen_string_literal: true

require "spec_helper"

RSpec.describe Onetime::EnableRefundPolicyForSellersWithRefundPolicies do
  let(:service) { described_class.new }

  describe ".reset_last_processed_seller_id" do
    it "deletes the redis key" do
      $redis.set(described_class::LAST_PROCESSED_ID_KEY, 123)

      described_class.reset_last_processed_seller_id

      expect($redis.get(described_class::LAST_PROCESSED_ID_KEY)).to be_nil
    end
  end

  describe "#process" do
    let!(:seller_without_policies) { create(:user) }
    let!(:seller_with_product_policy) { create(:user) }
    let!(:product) { create(:product, user: seller_with_product_policy) }
    let!(:product_refund_policy) { create(:product_refund_policy, product:, seller: seller_with_product_policy) }

    before do
      seller_without_policies.update!(refund_policy_enabled: false)
      seller_with_product_policy.update!(refund_policy_enabled: false)

      described_class.reset_last_processed_seller_id
    end

    it "enables refund policy for sellers with policies" do
      expect do
        service.process
      end.to have_enqueued_mail(ContactingCreatorMailer, :refund_policy_enabled_email).with(seller_with_product_policy.id)
         .and not_have_enqueued_mail(ContactingCreatorMailer, :refund_policy_enabled_email).with(seller_without_policies.id)

      expect(seller_with_product_policy.reload.refund_policy_enabled?).to be true
      expect(seller_with_product_policy.refund_policy.max_refund_period_in_days).to eq(30)
      expect(seller_without_policies.reload.refund_policy_enabled?).to be false
    end

    context "when the seller has all eligible refund policies as no refunds" do
      before do
        product_refund_policy.update!(max_refund_period_in_days: 0)
      end

      it "sets refund policy to no refunds for eligible sellers" do
        service.process

        refund_policy = seller_with_product_policy.reload.refund_policy
        expect(refund_policy.max_refund_period_in_days).to eq(0)
      end
    end

    it "processes sellers in batches and updates redis key" do
      allow(ReplicaLagWatcher).to receive(:watch)

      service.process

      expect(ReplicaLagWatcher).to have_received(:watch)
      expect($redis.get(described_class::LAST_PROCESSED_ID_KEY).to_i).to be > 0
    end
  end
end
