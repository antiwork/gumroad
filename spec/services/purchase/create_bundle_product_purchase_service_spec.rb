# frozen_string_literal: false

describe Purchase::CreateBundleProductPurchaseService do
  describe "#perform" do
    let(:seller) { create(:named_seller) }
    let(:purchaser) { create(:buyer_user) }
    let(:bundle) { create(:product, user: seller, is_bundle: true) }

    let(:versioned_product) { create(:product_with_digital_versions, user: seller, name: "Versioned product") }
    let!(:versioned_bundle_product) { create(:bundle_product, bundle:, product: versioned_product, variant: versioned_product.alive_variants.first, quantity: 3) }

    let(:purchase) { create(:purchase, link: bundle, purchaser:, zip_code: "12345", quantity: 2) }

    before do
      purchase.purchase_custom_fields << build(:purchase_custom_field, name: "Key", value: "Value", bundle_product: versioned_bundle_product)
    end

    it "creates a bundle product purchase" do
      described_class.new(purchase, versioned_bundle_product).perform

      bundle_product_purchase = Purchase.last

      expect(bundle_product_purchase.link).to eq(versioned_product)
      expect(bundle_product_purchase.quantity).to eq(6)
      expect(bundle_product_purchase.variant_attributes).to eq([versioned_product.alive_variants.first])

      expect(bundle_product_purchase.total_transaction_cents).to eq(0)
      expect(bundle_product_purchase.displayed_price_cents).to eq(0)
      expect(bundle_product_purchase.fee_cents).to eq(0)
      expect(bundle_product_purchase.price_cents).to eq(0)
      expect(bundle_product_purchase.gumroad_tax_cents).to eq(0)
      expect(bundle_product_purchase.shipping_cents).to eq(0)

      expect(bundle_product_purchase.is_bundle_product_purchase).to eq(true)
      expect(bundle_product_purchase.is_bundle_purchase).to eq(false)

      expect(bundle_product_purchase.purchaser).to eq(purchaser)
      expect(bundle_product_purchase.email).to eq(purchase.email)
      expect(bundle_product_purchase.full_name).to eq(purchase.full_name)
      expect(bundle_product_purchase.street_address).to eq(purchase.street_address)
      expect(bundle_product_purchase.country).to eq(purchase.country)
      expect(bundle_product_purchase.state).to eq(purchase.state)
      expect(bundle_product_purchase.zip_code).to eq(purchase.zip_code)
      expect(bundle_product_purchase.city).to eq(purchase.city)
      expect(bundle_product_purchase.ip_address).to eq(purchase.ip_address)
      expect(bundle_product_purchase.ip_state).to eq(purchase.ip_state)
      expect(bundle_product_purchase.ip_country).to eq(purchase.ip_country)
      expect(bundle_product_purchase.browser_guid).to eq(purchase.browser_guid)
      expect(bundle_product_purchase.referrer).to eq(purchase.referrer)
      expect(bundle_product_purchase.was_product_recommended).to eq(purchase.was_product_recommended)
      expect(bundle_product_purchase.purchase_custom_fields.sole).to have_attributes(name: "Key", value: "Value", bundle_product: nil)

      expect(purchase.product_purchases).to eq([bundle_product_purchase])
    end

    context "gifting a bundle" do
      let(:gifter_email) { "gifter@example.com" }
      let(:giftee_email) { "giftee@example.com" }

      let(:receiver_bundle_purchase) { create(:purchase, :gift_receiver, link: bundle, email: giftee_email) }
      let(:sender_bundle_purchase) { create(:purchase, :gift_sender, link: bundle, email: gifter_email) }

      let!(:bundle_level_gift) do
        create(
          :gift,
          link: bundle,
          gifter_purchase: sender_bundle_purchase,
          giftee_purchase: receiver_bundle_purchase,
          gifter_email: gifter_email,
          giftee_email: giftee_email
        )
      end

      before do
        receiver_bundle_purchase.reload
        sender_bundle_purchase.reload
      end

      it "creates a bundle product purchase with the correct is_gift_sender_purchase flag" do
        described_class.new(sender_bundle_purchase, versioned_bundle_product).perform

        bundle_product_purchase = Purchase.last

        expect(bundle_product_purchase.is_gift_sender_purchase).to eq(true)
        expect(bundle_product_purchase.is_gift_receiver_purchase).to eq(false)

        expect(bundle_product_purchase.gift).to be_present
        expect(bundle_product_purchase.gift.link).to eq(versioned_bundle_product.product)
        expect(bundle_product_purchase.gift.gifter_purchase).to eq(bundle_product_purchase)
        expect(bundle_product_purchase.gift.giftee_purchase).to be_nil
        expect(bundle_product_purchase.gift.gifter_email).to eq(gifter_email)
        expect(bundle_product_purchase.gift.giftee_email).to eq(giftee_email)
      end

      it "creates a bundle product purchase with the correct is_gift_receiver_purchase flag" do
        described_class.new(receiver_bundle_purchase, versioned_bundle_product).perform

        bundle_product_purchase = Purchase.last

        expect(bundle_product_purchase.is_gift_sender_purchase).to eq(false)
        expect(bundle_product_purchase.is_gift_receiver_purchase).to eq(true)

        expect(bundle_product_purchase.gift).to be_present
        expect(bundle_product_purchase.gift.link).to eq(versioned_bundle_product.product)
        expect(bundle_product_purchase.gift.gifter_purchase).to be_nil
        expect(bundle_product_purchase.gift.giftee_purchase).to eq(bundle_product_purchase)
        expect(bundle_product_purchase.gift.gifter_email).to eq(gifter_email)
        expect(bundle_product_purchase.gift.giftee_email).to eq(giftee_email)
      end
    end
  end
end
