# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillLicenseUsesForSeller do
  describe "#process" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }

    def create_purchase_with_license(seller:, product:, purchase_state: "successful")
      purchase = create(:purchase, seller:, link: product, purchase_state:)
      create(:license, link: product, purchase:)
      purchase
    end

    def update_jobs
      ElasticsearchIndexerWorker.jobs.select { |job| job["args"][0] == "update" }
    end

    it "enqueues a partial update for each of the seller's successful purchases with a license" do
      purchase_one = create_purchase_with_license(seller:, product:)
      purchase_two = create_purchase_with_license(seller:, product:)
      ElasticsearchIndexerWorker.jobs.clear

      described_class.new(seller:).process

      purchase_ids = update_jobs.map { |job| job["args"][1]["record_id"] }
      expect(purchase_ids).to match_array([purchase_one.id, purchase_two.id])
      expect(update_jobs).to all(include(
        "args" => ["update", hash_including("class_name" => "Purchase", "fields" => ["license_uses"])]
      ))
    end

    it "ignores purchases that belong to other sellers" do
      mine = create_purchase_with_license(seller:, product:)
      other_seller = create(:user)
      other_product = create(:product, user: other_seller)
      create_purchase_with_license(seller: other_seller, product: other_product)
      ElasticsearchIndexerWorker.jobs.clear

      described_class.new(seller:).process

      purchase_ids = update_jobs.map { |job| job["args"][1]["record_id"] }
      expect(purchase_ids).to eq([mine.id])
    end

    it "ignores purchases without a license" do
      create(:purchase, seller:, link: product)
      ElasticsearchIndexerWorker.jobs.clear

      described_class.new(seller:).process

      expect(update_jobs).to be_empty
    end

    it "ignores purchases that are not in a success state" do
      create_purchase_with_license(seller:, product:, purchase_state: "failed")
      ElasticsearchIndexerWorker.jobs.clear

      described_class.new(seller:).process

      expect(update_jobs).to be_empty
    end
  end
end
