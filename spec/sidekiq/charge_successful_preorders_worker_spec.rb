# frozen_string_literal: true

describe ChargeSuccessfulPreordersWorker do
  describe "#perform" do
    before do
      @product = create(:product, price_cents: 600, is_in_preorder_state: true)
      @preorder_product = create(:preorder_product_with_content, link: @product)
      @preorder_product.update_attribute(:release_at, Time.current) # bypass validation

      @preorder_1 = create(:preorder, preorder_link: @preorder_product, state: "authorization_failed")
      @preorder_2 = create(:preorder, preorder_link: @preorder_product, state: "authorization_successful")
      @preorder_3 = create(:preorder, preorder_link: @preorder_product, state: "charge_successful")
    end

    it "enqueues the proper preorders to be charged" do
      described_class.new.perform(@preorder_product.id)

      expect(ChargePreorderWorker).to have_enqueued_sidekiq_job(@preorder_2.id)
    end

    it "schedules a Sidekiq job to send preorder seller summary" do
      described_class.new.perform(@preorder_product.id)

      expect(SendPreorderSellerSummaryWorker).to have_enqueued_sidekiq_job(@preorder_product.id)
    end
  end
end
