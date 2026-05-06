require "spec_helper"

RSpec.describe InstallmentIdempotencyService do
  let(:seller) { create(:user) }
  let(:key) { SecureRandom.uuid }
  let(:installment) { create(:installment, seller:) }

  describe ".reserve" do
    it "returns :reserved on first call" do
      expect(described_class.reserve(seller_id: seller.id, key:)).to eq(:reserved)
    end

    it "returns :in_flight on concurrent call before completion" do
      described_class.reserve(seller_id: seller.id, key:)
      expect(described_class.reserve(seller_id: seller.id, key:)).to eq(:in_flight)
    end

    it "returns the installment after completion" do
      described_class.reserve(seller_id: seller.id, key:)
      described_class.complete(seller_id: seller.id, key:, installment_id: installment.id)
      expect(described_class.reserve(seller_id: seller.id, key:)).to eq(installment)
    end
  end

  describe ".release" do
    it "deletes the in-flight sentinel" do
      described_class.reserve(seller_id: seller.id, key:)
      described_class.release(seller_id: seller.id, key:)
      expect(described_class.reserve(seller_id: seller.id, key:)).to eq(:reserved)
    end
  end
end
