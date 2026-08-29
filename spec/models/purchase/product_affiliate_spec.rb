# frozen_string_literal: true

require "spec_helper"

describe Purchase, "product affiliate assignment" do
  let(:product) { create(:product) }
  let(:affiliate) { create(:user).global_affiliate }

  it "keeps repeated global affiliate assignments idempotent" do
    purchase = build(:purchase, link: product, affiliate:)

    2.times { purchase.send(:create_product_affiliate) }

    expect(ProductAffiliate.where(affiliate:, product:).count).to eq(1)
  end

  # state_machines terminates the after_transition chain on a callback that returns exactly
  # false, so this one must never hand back create_if_missing!'s "already assigned" boolean.
  # Everything queued after it — the sale ping included — is skipped silently otherwise.
  it "does not return false when the assignment already exists" do
    ProductAffiliate.create_if_missing!(affiliate:, product:)
    purchase = build(:purchase, link: product, affiliate:)

    expect(purchase.send(:create_product_affiliate)).not_to eq(false)
  end

  describe "callbacks queued after the assignment" do
    it "sends the sale notification webhook when the assignment already exists" do
      ProductAffiliate.create_if_missing!(affiliate:, product:)
      purchase = create(:purchase, link: product, affiliate:, purchase_state: "in_progress")

      purchase.mark_successful!

      expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(purchase.id, nil)
    end

    it "sends the sale notification webhook when the assignment is created by this sale" do
      purchase = create(:purchase, link: product, affiliate:, purchase_state: "in_progress")

      purchase.mark_successful!

      expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(purchase.id, nil)
    end

    it "indexes the sale when the assignment already exists" do
      ProductAffiliate.create_if_missing!(affiliate:, product:)
      purchase = create(:purchase, link: product, affiliate:, purchase_state: "in_progress")

      expect(purchase).to receive(:update_product_search_index!)

      purchase.mark_successful!
    end
  end
end
