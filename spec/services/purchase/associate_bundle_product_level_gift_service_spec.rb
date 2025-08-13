# frozen_string_literal: false

describe Purchase::AssociateBundleProductLevelGiftService do
  describe "#perform" do
    let(:seller) { create(:named_seller) }
    let(:gifter_email) { "gifter@example.com" }
    let(:giftee_email) { "giftee@example.com" }

    let(:bundle) { create(:product, :bundle, user: seller) }
    let(:bundle_product) { bundle.bundle_products.first }

    let!(:sender_bundle_purchase) { create(:purchase, :gift_sender, link: bundle, email: gifter_email) }
    let!(:receiver_bundle_purchase) { create(:purchase, :gift_receiver, link: bundle, email: giftee_email) }

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

    let(:sender_product_purchase) do
      create(
        :bundle_product_purchase,
        bundle_purchase: sender_bundle_purchase,
        product_purchase: create(:purchase, link: bundle_product.product, seller:, is_gift_sender_purchase: true, is_bundle_product_purchase: true)
      ).product_purchase
    end
    let(:receiver_product_purchase) do
      create(
        :bundle_product_purchase,
        bundle_purchase: receiver_bundle_purchase,
        product_purchase: create(:purchase, link: bundle_product.product, seller:, is_gift_receiver_purchase: true, is_bundle_product_purchase: true)
      ).product_purchase
    end

    before do
      sender_bundle_purchase.reload
      receiver_bundle_purchase.reload
    end

    context "when both product purchases exist" do
      before do
        sender_product_purchase
        receiver_product_purchase
      end

      it "creates a full Gift record" do
        expect do
          described_class.new(bundle_purchase: sender_bundle_purchase, bundle_product: bundle_product).perform
        end.to change(Gift, :count).by(1)

        product_level_gift = sender_product_purchase.reload.gift

        expect(product_level_gift.link).to eq(bundle_product.product)
        expect(product_level_gift.gifter_purchase).to eq(sender_product_purchase)
        expect(product_level_gift.giftee_purchase).to eq(receiver_product_purchase)
        expect(product_level_gift.gifter_email).to eq(gifter_email)
        expect(product_level_gift.giftee_email).to eq(giftee_email)
        expect(product_level_gift.id).not_to eq(bundle_level_gift.id)

        # Re-running should not create a duplicate when both sides present
        expect do
          described_class.new(bundle_purchase: sender_bundle_purchase, bundle_product: bundle_product).perform
        end.to change(Gift, :count).by(0)
      end

      it "is indifferent to which bundle purchase instance is passed (sender or receiver)" do
        described_class.new(bundle_purchase: receiver_bundle_purchase, bundle_product: bundle_product).perform

        product_level_gift = Gift.where(gifter_purchase: sender_product_purchase).first!

        expect(product_level_gift.giftee_purchase).to eq(receiver_product_purchase)
        expect(product_level_gift.link).to eq(bundle_product.product)
      end
    end

    context "when bundle_product does not belong to the bundle" do
      it "does nothing" do
        unrelated_bundle = create(:product, :bundle, user: seller)
        unrelated_bundle_product = unrelated_bundle.bundle_products.first

        expect do
          described_class.new(bundle_purchase: sender_bundle_purchase, bundle_product: unrelated_bundle_product).perform
        end.to change(Gift, :count).by(0)
      end
    end

    context "when only one side's product purchase exists" do
      it "creates a Gift with the available side associated" do
        # Only the sender's product purchase exists.
        sender_product_purchase

        expect do
          described_class.new(bundle_purchase: sender_bundle_purchase, bundle_product: bundle_product).perform
        end.to change(Gift, :count).by(1)

        # Product level gift is created with the sender's product purchase only.
        product_level_gift = sender_product_purchase.reload.gift

        expect(product_level_gift.link).to eq(bundle_product.product)
        expect(product_level_gift.gifter_purchase).to eq(sender_product_purchase)
        expect(product_level_gift.giftee_purchase).to be_nil
        expect(product_level_gift.gifter_email).to eq(gifter_email)
        expect(product_level_gift.giftee_email).to eq(giftee_email)

        # Now, the receiver's product purchase is created too.
        receiver_product_purchase

        expect do
          described_class.new(bundle_purchase: receiver_bundle_purchase, bundle_product: bundle_product).perform
        end.to change(Gift, :count).by(0)

        # The product level gift is updated to include the receiver's product purchase.
        product_level_gift.reload

        expect(product_level_gift.link).to eq(bundle_product.product)
        expect(product_level_gift.gifter_purchase).to eq(sender_product_purchase)
        expect(product_level_gift.giftee_purchase).to eq(receiver_product_purchase)
        expect(product_level_gift.gifter_email).to eq(gifter_email)
        expect(product_level_gift.giftee_email).to eq(giftee_email)
      end
    end
  end
end
