# frozen_string_literal: true

require "spec_helper"

describe "PurchaseGifts", :vcr do
  include CurrencyHelper
  include ProductsHelper

  describe "gifts" do
    before do
      gifter_email = "gifter@foo.com"
      giftee_email = "giftee@foo.com"
      @product = create(:product)
      gift = create(:gift, gifter_email:, giftee_email:, link: @product)
      @gifter_purchase = create(:purchase_in_progress, link: @product, email: gifter_email, chargeable: create(:chargeable))
      gift.gifter_purchase = @gifter_purchase
      @gifter_purchase.is_gift_sender_purchase = true
      @gifter_purchase.process!

      @giftee_purchase = gift.giftee_purchase = create(:purchase, link: @product, seller: @product.user, email: giftee_email, price_cents: 0,
                                                                  stripe_transaction_id: nil, stripe_fingerprint: nil,
                                                                  is_gift_receiver_purchase: true, purchase_state: "in_progress")
      gift.mark_successful
      gift.save!
    end

    it "increments seller's balance only for one purchase" do
      expect do
        @giftee_purchase.mark_gift_receiver_purchase_successful
        @gifter_purchase.update_balance_and_mark_successful!
      end.to change {
        @product.user.reload.unpaid_balance_cents
      }.by(@gifter_purchase.payment_cents)
    end

    it "sets the state of the giftee purchase to refunded when refunding gifter purchase" do
      @giftee_purchase.mark_gift_receiver_purchase_successful
      @gifter_purchase.reload.refund_and_save!(create(:admin_user).id)
      @giftee_purchase.reload
      expect(@giftee_purchase.purchase_state).to eq("gift_receiver_purchase_successful")
      expect(@giftee_purchase.stripe_refunded).to be(true)
    end

    it "creates 1 url_redirect" do
      expect do
        @giftee_purchase.mark_gift_receiver_purchase_successful
        @gifter_purchase.update_balance_and_mark_successful!
      end.to change {
        UrlRedirect.count
      }.by(1)
    end

    it "emails the buyer" do
      @giftee_purchase.mark_gift_receiver_purchase_successful
      expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(@giftee_purchase.id).on("critical")

      @gifter_purchase.update_balance_and_mark_successful!
      expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(@gifter_purchase.id).on("critical")
    end

    it "emails the seller once" do
      mail_double = double
      allow(mail_double).to receive(:deliver_later)
      expect(ContactingCreatorMailer).to receive(:notify).and_return(mail_double)
      @giftee_purchase.mark_gift_receiver_purchase_successful
      @gifter_purchase.update_balance_and_mark_successful!
    end

    describe "gifts with shipping" do
      before do
        @gifter_purchase = create(:purchase, price_cents: 100_00, chargeable: create(:chargeable))

        @gifter_purchase.link.price_cents = 100_00
        @gifter_purchase.link.shipping_destinations << ShippingDestination.new(country_code: Compliance::Countries::USA.alpha2, one_item_rate_cents: 10_00, multiple_items_rate_cents: 5_00)
        @gifter_purchase.link.is_physical = true
        @gifter_purchase.link.require_shipping = true
        @gifter_purchase.link.save!
      end

      it "does not apply a price or shipping rate to the giftee purchase" do
        @gifter_purchase.country = "United States"
        @gifter_purchase.zip_code = 94_107
        @gifter_purchase.state = "CA"

        @gifter_purchase.quantity = 1
        @gifter_purchase.save!

        @gifter_purchase.process!

        expect(@gifter_purchase.price_cents).to eq(110_00)
        expect(@gifter_purchase.shipping_cents).to eq(10_00)
        expect(@gifter_purchase.total_transaction_cents).to eq(110_00)

        @giftee_purchase = create(:purchase, link: @gifter_purchase.link, seller: @gifter_purchase.link.user, email: "giftee_email@gumroad.com",
                                             price_cents: 0, stripe_transaction_id: nil, stripe_fingerprint: nil, is_gift_receiver_purchase: true,
                                             full_name: "Mr.Dumbot Dumstein", country: Compliance::Countries::USA.common_name, state: "CA",
                                             city: "San Francisco", zip_code: "94107", street_address: "1640 17th St",
                                             purchase_state: "in_progress", can_contact: true)

        @giftee_purchase.process!

        expect(@giftee_purchase.price_cents).to eq(0)
        expect(@giftee_purchase.shipping_cents).to eq(0)
        expect(@giftee_purchase.total_transaction_cents).to eq(0)
        expect(@giftee_purchase.tax_cents).to eq(0)
        expect(@giftee_purchase.fee_cents).to eq(0)
      end
    end

    it "makes one url redirect" do
      expect do
        @giftee_purchase.mark_gift_receiver_purchase_successful
        @gifter_purchase.update_balance_and_mark_successful!
      end.to change(UrlRedirect, :count).by(1)
      expect(@giftee_purchase.url_redirect).to eq UrlRedirect.last
      expect(@gifter_purchase.url_redirect).to be(nil)
    end
  end
end
