# frozen_string_literal: true

require "spec_helper"

describe SendPreorderSellerSummaryWorker, :vcr do
  before do
    travel_to 2.days.ago
    @product = create(:product, price_cents: 600, is_in_preorder_state: false)
    @preorder_product = create(:preorder_product_with_content, link: @product, release_at: 2.days.from_now)
    travel_back
    @card_will_succeed = build(:chargeable)
    @card_will_decline = build(:chargeable_success_charge_decline)
    @mail_double = double
    allow(@mail_double).to receive(:deliver_later)
  end

  it "sends the summary email if all preorders are charged" do
    authorization_purchase = build(:purchase, link: @product, chargeable: @card_will_succeed, purchase_state: "in_progress", is_preorder_authorization: true)
    preorder = @preorder_product.build_preorder(authorization_purchase)
    preorder.authorize!
    preorder.mark_authorization_successful
    preorder.charge!

    expect(ContactingCreatorMailer).to receive(:preorder_summary).with(@preorder_product.id).and_return(@mail_double)
    SendPreorderSellerSummaryWorker.new.perform(@preorder_product.id)
  end

  it "does not send the summary email if there are un-charged preorders" do
    authorization_purchase = build(:purchase, link: @product, chargeable: @card_will_succeed, purchase_state: "in_progress", is_preorder_authorization: true)
    preorder = @preorder_product.build_preorder(authorization_purchase)
    preorder.authorize!
    preorder.mark_authorization_successful
    # Should not count `in_progress` purchases towards preorder being charged
    create(:purchase_in_progress, link: @product, preorder:, chargeable: @card_will_succeed)

    expect(ContactingCreatorMailer).to_not receive(:preorder_summary).with(@preorder_product.id)
    SendPreorderSellerSummaryWorker.new.perform(@preorder_product.id)

    # since we weren't done charging all the cards it should have queued the summary job again.
    expect(SendPreorderSellerSummaryWorker).to have_enqueued_sidekiq_job(@preorder_product.id, anything)
  end

  it "sends the summary email if the preorder was charged and failed" do
    authorization_purchase = build(:purchase, link: @product, chargeable: @card_will_decline, purchase_state: "in_progress",
                                              is_preorder_authorization: true)
    preorder = @preorder_product.build_preorder(authorization_purchase)
    preorder.authorize!
    preorder.mark_authorization_successful
    preorder.charge!

    expect(ContactingCreatorMailer).to receive(:preorder_summary).with(@preorder_product.id).and_return(@mail_double)
    SendPreorderSellerSummaryWorker.new.perform(@preorder_product.id)
  end

  context "when preorders take more than 24h to charge" do
    it "stops waiting and notifies Bugsnag", :sidekiq_inline do
      authorization_purchase = build(:purchase, link: @product, chargeable: @card_will_decline, purchase_state: "in_progress",
                                                is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      preorder.mark_authorization_successful

      expect(ContactingCreatorMailer).not_to receive(:preorder_summary).with(@preorder_product.id)
      expect(SendPreorderSellerSummaryWorker).to receive(:perform_in).with(20.minutes, @preorder_product.id, anything).exactly(72).times.and_call_original
      expect(Bugsnag).to receive(:notify).with("Timed out waiting for all preorders to be charged. PreorderLink: #{@preorder_product.id}.")

      expect do
        SendPreorderSellerSummaryWorker.new.perform(@preorder_product.id)
      end.to raise_error(/Timed out waiting for all preorders to be charged/)
    end
  end
end
