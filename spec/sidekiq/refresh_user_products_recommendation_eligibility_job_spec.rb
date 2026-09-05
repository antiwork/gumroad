# frozen_string_literal: true

require "spec_helper"

describe RefreshUserProductsRecommendationEligibilityJob do
  it "dedupes queued scans while allowing a transition during a scan to enqueue a follow-up" do
    expect(described_class.sidekiq_options).to include(
      "lock" => :until_executing,
      "lock_ttl" => 6.hours.to_i,
      "on_conflict" => { "client" => :log }
    )
  end

  it "updates recommendation eligibility for every seller product" do
    seller = create(:user)
    products = create_list(:product, 2, user: seller)
    updated_product_ids = []
    expect(ProductIndexingService).to receive(:perform).twice do |product:, action:, attributes_to_update:, on_failure:|
      updated_product_ids << product.id
      expect(action).to eq("update")
      expect(attributes_to_update).to eq(%w[is_recommendable])
      expect(on_failure).to eq(:async)
    end

    described_class.new.perform(seller.id)

    expect(updated_product_ids).to match_array(products.map(&:id))
  end

  it "does nothing when the seller no longer exists" do
    expect { described_class.new.perform(0) }.not_to raise_error
  end
end
