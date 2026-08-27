# frozen_string_literal: true

describe Post::Caching do
  let(:installment) { create(:installment) }

  describe "#key_for_cache" do
    it "namespaces keys by the read source so legacy cached counters cannot survive the production flip" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      Feature.deactivate(:email_engagement_dynamodb_reads)
      expect(installment.key_for_cache(:unique_open_count)).to eq("unique_open_count_for_installment_#{installment.id}")

      Feature.activate(:email_engagement_dynamodb_reads)
      expect(installment.key_for_cache(:unique_open_count)).to eq("unique_open_count_for_installment_#{installment.id}_ddb")
    ensure
      Feature.deactivate(:email_engagement_dynamodb_reads)
    end
  end

  describe "#invalidate_cache" do
    it "deletes the key in the active namespace" do
      expect(Rails.cache).to receive(:delete).with("unique_click_count_for_installment_#{installment.id}_ddb")

      installment.invalidate_cache(:unique_click_count)
    end
  end
end
