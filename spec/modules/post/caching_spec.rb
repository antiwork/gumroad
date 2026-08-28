# frozen_string_literal: true

describe Post::Caching do
  let(:installment) { create(:installment) }

  describe "#key_for_cache" do
    it "keeps engagement counters in the DynamoDB cache namespace" do
      expect(installment.key_for_cache(:unique_open_count)).to eq("unique_open_count_for_installment_#{installment.id}_ddb")
      expect(installment.key_for_cache(:unique_open_count, dynamodb_reads: false)).to eq("unique_open_count_for_installment_#{installment.id}")
    end
  end

  describe "#invalidate_cache" do
    it "deletes the key in the active namespace" do
      expect(Rails.cache).to receive(:delete).with("unique_click_count_for_installment_#{installment.id}_ddb")

      installment.invalidate_cache(:unique_click_count)
    end
  end

  describe "#invalidate_legacy_engagement_cache" do
    it "deletes the unsuffixed key even while DynamoDB reads are enabled" do
      expect(Rails.cache).to receive(:delete).with("unique_click_count_for_installment_#{installment.id}")

      installment.invalidate_legacy_engagement_cache(:unique_click_count)
    end
  end
end
