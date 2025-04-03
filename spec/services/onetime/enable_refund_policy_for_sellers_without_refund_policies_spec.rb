# frozen_string_literal: true

require "spec_helper"

RSpec.describe Onetime::EnableRefundPolicyForSellersWithoutRefundPolicies do
  let(:service) { described_class.new }

  describe ".reset_last_processed_seller_id" do
    it "deletes the redis key" do
      $redis.set(described_class::LAST_PROCESSED_SELLER_ID_KEY, 123)

      described_class.reset_last_processed_seller_id

      expect($redis.get(described_class::LAST_PROCESSED_SELLER_ID_KEY)).to be_nil
    end
  end

  describe "#process" do
    let!(:seller1) { create(:user, username: "seller1") }
    let!(:seller2) { create(:user, username: "seller2") }
    let!(:seller_with_product_policy) { create(:user, username: "sellerwithpolicies") }
    let!(:product) { create(:product, user: seller_with_product_policy) }
    let!(:product_refund_policy) { create(:product_refund_policy, product:, seller: seller_with_product_policy) }

    before do
      seller1.update!(refund_policy_enabled: false)
      seller2.update!(refund_policy_enabled: false)
      seller_with_product_policy.update!(refund_policy_enabled: false)

      described_class.reset_last_processed_seller_id
    end

    it "enables refund policy for eligible sellers" do
      service.process

      expect(seller1.reload.refund_policy_enabled?).to be true
      expect(seller2.reload.refund_policy_enabled?).to be true
    end

    it "skips sellers who have product refund policies" do
      service.process

      expect(seller_with_product_policy.reload.refund_policy_enabled?).to be false
    end

    it "processes sellers in batches and updates redis key" do
      allow(ReplicaLagWatcher).to receive(:watch)

      service.process

      expect(ReplicaLagWatcher).to have_received(:watch)
      expect($redis.get(described_class::LAST_PROCESSED_SELLER_ID_KEY).to_i).to eq(User.last.id)
    end

    context "when resuming from last processed id" do
      before do
        $redis.set(described_class::LAST_PROCESSED_SELLER_ID_KEY, seller1.id)
      end

      it "starts from the next seller after last processed id" do
        service.process

        expect(seller1.reload.refund_policy_enabled?).to be false
        expect(seller2.reload.refund_policy_enabled?).to be true
      end
    end
  end
end
