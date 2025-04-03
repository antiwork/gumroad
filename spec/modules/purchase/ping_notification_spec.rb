# frozen_string_literal: true

require "spec_helper"

describe Purchase::PingNotification, :vcr do
  describe "#payload_for_ping_notification" do
    it "contains the correct resource_name" do
      purchase = create(:purchase, stripe_refunded: true)

      [ResourceSubscription::SALE_RESOURCE_NAME, ResourceSubscription::REFUNDED_RESOURCE_NAME].each do |resource_name|
        params = purchase.payload_for_ping_notification(resource_name:)
        expect(params[:resource_name]).to eq(resource_name)
      end
    end

    it "contains the 'refunded' key if the input resource_name is 'refunded'" do
      purchase = create(:purchase, stripe_refunded: true)
      params = purchase.payload_for_ping_notification(resource_name: ResourceSubscription::REFUNDED_RESOURCE_NAME)

      expect(params[:refunded]).to be(true)
    end

    it "contains the 'disputed' key set to true if purchase is chargebacked, else false" do
      purchase = create(:purchase)
      params = purchase.payload_for_ping_notification(resource_name: ResourceSubscription::DISPUTE_RESOURCE_NAME)

      expect(params[:disputed]).to be(false)

      purchase.chargeback_date = Date.today
      purchase.save!
      params = purchase.reload.payload_for_ping_notification(resource_name: ResourceSubscription::DISPUTE_RESOURCE_NAME)

      expect(params[:disputed]).to be(true)
    end

    it "contains the 'dispute_won' key set to true if purchase is chargeback_reversed, else false" do
      purchase = create(:purchase, chargeback_date: Date.today)
      params = purchase.payload_for_ping_notification(resource_name: ResourceSubscription::DISPUTE_WON_RESOURCE_NAME)

      expect(params[:dispute_won]).to be(false)

      purchase.chargeback_reversed = true
      purchase.save!
      params = purchase.reload.payload_for_ping_notification(resource_name: ResourceSubscription::DISPUTE_WON_RESOURCE_NAME)

      expect(params[:dispute_won]).to be(true)
    end

    it "has the correct value for 'discover_fee_charged'" do
      purchase = create(:purchase, was_discover_fee_charged: true)
      params = purchase.reload.payload_for_ping_notification

      expect(params[:discover_fee_charged]).to be(true)
    end

    it "has the correct value for 'can_contact'" do
      purchase = create(:purchase, can_contact: nil)
      params = purchase.reload.payload_for_ping_notification

      expect(params[:can_contact]).to be(false)
    end

    it "has the correct value for 'referrer'" do
      referrer  = "https://myreferrer.com"
      purchase  = create(:purchase, referrer:)
      params    = purchase.reload.payload_for_ping_notification

      expect(params[:referrer]).to eq(referrer)
    end

    it "has the correct value for 'gumroad_fee'" do
      purchase = create(:purchase, price_cents: 500)
      params   = purchase.reload.payload_for_ping_notification

      expect(params[:gumroad_fee]).to be(145) # 500 * 0.129 + 50c + 30c
    end

    it "has the correct value for 'card'" do
      purchaser = create(:user, credit_card: create(:credit_card))
      purchase  = create(:purchase, price_cents: 500, purchaser:)
      params    = purchase.reload.payload_for_ping_notification

      expect(params[:card]).to eq({
                                    bin: nil,
                                    expiry_month: nil,
                                    expiry_year: nil,
                                    type: "visa",
                                    visual: "**** **** **** 4062"
                                  })
    end

    it "has the correct link information" do
      purchase = create(:purchase)
      product = purchase.link
      unique_permalink = product.unique_permalink
      custom_permalink = "GreatestProductEver"
      product.update!(custom_permalink:)

      payload = purchase.reload.payload_for_ping_notification

      expect(payload[:permalink]).to eq(custom_permalink)
      expect(payload[:product_permalink]).to eq(product.long_url)
      expect(payload[:short_product_id]).to eq(unique_permalink)
    end

    it "doesn't set the card expiry month and year fields" do
      purchase = create(:purchase, card_expiry_month: 11, card_expiry_year: 2022)
      payload = purchase.reload.payload_for_ping_notification

      expect(payload[:card][:expiry_month]).to be_nil
      expect(payload[:card][:expiry_year]).to be_nil
    end

    describe "custom fields" do
      let(:purchase) { create(:purchase) }

      context "when purchase has custom fields set" do
        before do
          purchase.purchase_custom_fields << build(:purchase_custom_field, name: "name", value: "Amy")
        end

        it "includes the purchase's custom fields" do
          params = purchase.payload_for_ping_notification(resource_name: ResourceSubscription::SALE_RESOURCE_NAME)

          expect(params[:custom_fields].keys).to eq ["name"]
          expect(params[:custom_fields]["name"]).to eq "Amy"
        end
      end

      context "when the purchase does not have custom fields set" do
        context "and is not a subscription purchase" do
          it "does not include the 'custom_fields' key" do
            params = purchase.payload_for_ping_notification(resource_name: ResourceSubscription::SALE_RESOURCE_NAME)

            expect(params.has_key?(:custom_fields)).to eq false
          end
        end

        context "and is a subscription purchase" do
          let(:sub) { create(:subscription) }
          let(:original_purchase) { create(:membership_purchase, subscription: sub) }
          let(:purchase) { create(:membership_purchase, subscription: sub, is_original_subscription_purchase: false) }

          it "includes the subscription's 'custom_fields'" do
            original_purchase.purchase_custom_fields << build(:purchase_custom_field, name: "name", value: "Amy")
            params = purchase.payload_for_ping_notification(resource_name: ResourceSubscription::SALE_RESOURCE_NAME)

            expect(params[:custom_fields].keys).to eq ["name"]
            expect(params[:custom_fields]["name"]).to eq "Amy"

            original_purchase.purchase_custom_fields.destroy_all
            sub.reload

            params = purchase.payload_for_ping_notification(resource_name: ResourceSubscription::SALE_RESOURCE_NAME)
            expect(params.has_key?(:custom_fields)).to eq false
          end
        end
      end
    end

    describe "is_multiseat_license" do
      context "when the purchased product is licensed" do
        it "includes the 'is_multiseat_license' key" do
          product = create(:membership_product, is_licensed: true, is_multiseat_license: true)
          purchase = create(:membership_purchase, link: product, license: create(:license))
          params = purchase.payload_for_ping_notification(resource_name: ResourceSubscription::SALE_RESOURCE_NAME)
          expect(params.has_key?(:is_multiseat_license)).to eq true
          expect(params[:is_multiseat_license]).to eq true

          product = create(:membership_product, is_licensed: true, is_multiseat_license: false)
          purchase = create(:membership_purchase, link: product, license: create(:license))
          params = purchase.payload_for_ping_notification(resource_name: ResourceSubscription::SALE_RESOURCE_NAME)
          expect(params.has_key?(:is_multiseat_license)).to eq true
          expect(params[:is_multiseat_license]).to eq false
        end
      end

      context "when the purchased product is not licensed" do
        it "does not include the 'is_multiseat_license' key" do
          product = create(:membership_product, is_licensed: false)
          purchase = create(:membership_purchase, link: product)
          params = purchase.payload_for_ping_notification(resource_name: ResourceSubscription::SALE_RESOURCE_NAME)

          expect(params.has_key?(:is_multiseat_license)).to eq false
        end
      end
    end
  end

  context "when the product is physical with variants" do
    let(:variant) { create(:variant) }
    let(:purchase) { create(:purchase, variant_attributes: [variant]) }

    before do
      purchase.link.is_physical = true
    end

    it "includes sku_id in the payload" do
      params = purchase.payload_for_ping_notification

      expect(params[:sku_id]).to eq(variant.external_id)
      expect(params[:original_sku_id]).to be_nil
    end
  end
end
