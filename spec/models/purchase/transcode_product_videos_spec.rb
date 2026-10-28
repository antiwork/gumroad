# frozen_string_literal: true

require "spec_helper"

describe Purchase do
  describe "#transcode_product_videos" do
    let(:seller) { create(:named_seller) }
    let(:bundle) { create(:product, :bundle, user: seller, transcode_videos_on_purchase: true) }
    let(:merchant_account) { MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) || create(:merchant_account) }
    let(:purchase) do
      create(:purchase_in_progress, link: bundle, merchant_account:,
                                    charge_processor_id: StripeChargeProcessor.charge_processor_id)
    end

    it "finalizes a purchase of a bundle that has lost all its products" do
      bundle.bundle_products.each { _1.mark_deleted(validate: false) }

      expect { purchase.mark_successful! }.not_to raise_error
      expect(purchase.reload).to be_successful
      expect(bundle.reload.transcode_videos_on_purchase).to be(false)
    end
  end
end
