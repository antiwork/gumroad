# frozen_string_literal: true

require "spec_helper"

RSpec.describe Onetime::RevertToProductLevelRefundPolicies do
  describe ".reset_last_processed_id" do
    before do
      $redis.set(described_class::LAST_PROCESSED_ID_KEY, 123)
    end

    it "clears the last processed ID" do
      expect { described_class.reset_last_processed_id }.to change {
        $redis.get(described_class::LAST_PROCESSED_ID_KEY)
      }.from("123").to(nil)
    end
  end

  describe "#initialize" do
    let!(:seller) { create(:user, refund_policy_enabled: true) }
    let(:seller_ids) { [seller.id] }

    it "accepts seller IDs directly" do
      service = described_class.new(seller_ids: seller_ids)
      expect(service.seller_ids).to eq(seller_ids)
    end

    it "raises error when seller_ids is empty" do
      expect { described_class.new(seller_ids: []) }.to raise_error(ArgumentError, /Seller ids not found/)
    end
  end

  describe "#process" do
    let!(:seller_with_refund) { create(:user) }

    before do
      described_class.reset_last_processed_id
      allow(Rails.logger).to receive(:info)
      allow(ReplicaLagWatcher).to receive(:watch)
      seller_with_refund.update!(refund_policy_enabled: true)
    end

    it "watches for replica lag" do
      service = described_class.new(seller_ids: [seller_with_refund.id])
      service.process
      expect(ReplicaLagWatcher).to have_received(:watch)
    end

    it "skips sellers that were already processed in previous runs" do
      $redis.set(described_class::LAST_PROCESSED_ID_KEY, 0)

      service = described_class.new(seller_ids: [seller_with_refund.id])
      service.process

      expect(Rails.logger).to have_received(:info).with(/Seller: #{seller_with_refund.id}.*skipped \(already processed in previous run\)/)
    end

    it "skips inactive sellers" do
      allow_any_instance_of(User).to receive(:account_active?).and_return(false)
      service = described_class.new(seller_ids: [seller_with_refund.id])

      expect do
        service.process
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :product_level_refund_policies_reverted)

      expect(Rails.logger).to have_received(:info).with(/Seller: #{seller_with_refund.id}.*skipped \(not active\)/)
    end

    it "processes active sellers with refund_policy_enabled=true" do
      service = described_class.new(seller_ids: [seller_with_refund.id])

      expect do
        service.process
      end.to have_enqueued_mail(ContactingCreatorMailer, :product_level_refund_policies_reverted).with(seller_with_refund.id)

      expect(Rails.logger).to have_received(:info).with(/Seller: #{seller_with_refund.id}.*processed and email sent/)

      expect(seller_with_refund.reload.refund_policy_enabled?).to be false
    end

    it "does not send emails to sellers with refund_policy_enabled=false" do
      seller_without_refund = create(:user)
      seller_without_refund.update!(refund_policy_enabled: false)

      service = described_class.new(seller_ids: [seller_without_refund.id])

      expect do
        service.process
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :product_level_refund_policies_reverted)

      expect(Rails.logger).to have_received(:info).with(/Seller: #{seller_without_refund.id}.*skipped \(already processed\)/)
    end

    it "updates Redis with the last processed index" do
      service = described_class.new(seller_ids: [seller_with_refund.id])
      allow($redis).to receive(:set).and_call_original

      service.process

      expect($redis).to have_received(:set).with(
        described_class::LAST_PROCESSED_ID_KEY,
        kind_of(Integer),
        ex: 1.month
      ).once
    end

    it "handles errors during processing and tracks invalid seller IDs" do
      error_seller = create(:user)
      error_seller.update_column(:flags, error_seller.flags | (1 << 46))
      expect(error_seller.refund_policy_enabled?).to be true

      service = described_class.new(seller_ids: [seller_with_refund.id, error_seller.id])

      allow(User).to receive(:find).and_call_original
      allow(User).to receive(:find).with(error_seller.id).and_raise(StandardError.new("Test error"))

      expect do
        service.process
      end.to have_enqueued_mail(ContactingCreatorMailer, :product_level_refund_policies_reverted).with(seller_with_refund.id)
          .and not_have_enqueued_mail(ContactingCreatorMailer, :product_level_refund_policies_reverted).with(error_seller.id)

      expect(service.invalid_seller_ids).to include(a_hash_including(error_seller.id => "Test error"))
    end
  end
end
