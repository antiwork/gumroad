# frozen_string_literal: true

require "spec_helper"

describe CreateLicensesForExistingCustomersWorker do
  describe "#perform" do
    before(:each) do
      @purchase1 = create(:purchase)
      @product = @purchase1.link
      @purchase2 = create(:purchase, link: @product)
      @purchase3 = create(:purchase, link: @product)
    end

    it "creates licenses for past purchases" do
      expect do
        described_class.new.perform(@product.id)
      end.to change { @product.licenses.count }.from(0).to(3)

      expect(@product.licenses.map(&:purchase_id)).to match_array([@purchase1.id, @purchase2.id, @purchase3.id])
    end

    it "creates licenses for past purchases only if they do not already exist" do
      create(:license, purchase: @purchase1, link: @product)
      create(:license, purchase: @purchase3, link: @product)

      expect do
        described_class.new.perform(@product.id)
      end.to change { @product.licenses.count }.from(2).to(3)

      expect(@product.licenses.map(&:purchase_id)).to match_array([@purchase1.id, @purchase2.id, @purchase3.id])
    end

    it "creates licenses for giftee purchases but not gifter purchases" do
      gift = create(:gift, link: @product)
      gifter_purchase = create(:purchase_in_progress, link: @product, is_gift_sender_purchase: true)
      gifter_purchase.process!
      gifter_purchase.mark_successful!
      gift.gifter_purchase = gifter_purchase
      gifter_purchase.is_gift_sender_purchase = true
      gift.giftee_purchase = create(:purchase, link: @product, price_cents: 0,
                                               is_gift_receiver_purchase: true,
                                               purchase_state: "gift_receiver_purchase_successful")
      gift.mark_successful
      gift.save!

      expect do
        described_class.new.perform(@product.id)
      end.to change { @product.licenses.count }.from(0).to(4)

      expect(@product.licenses.map(&:purchase_id)).to(
        match_array([@purchase1.id, @purchase2.id, @purchase3.id, gift.giftee_purchase.id])
      )
    end

    it "creates licenses for only the original purchases of subscriptions and not the recurring charges" do
      user = create(:user)
      subscription = create(:subscription, user:, link: @product)
      original_subscription_purchase = create(:purchase, link: @product, email: user.email, is_original_subscription_purchase: true, subscription:)
      create(:purchase, link: @product, email: user.email, is_original_subscription_purchase: false, subscription:)

      expect do
        described_class.new.perform(@product.id)
      end.to change { @product.licenses.count }.from(0).to(4)
      expect(@product.licenses.map(&:purchase_id)).to(match_array([@purchase1.id, @purchase2.id, @purchase3.id, original_subscription_purchase.id]))
    end

    it "skips purchases of variants whose per-variant content has no license-key block" do
      category = create(:variant_category, link: @product)
      free_variant = create(:variant, variant_category: category)
      pro_variant = create(:variant, variant_category: category)
      create(:rich_content, entity: free_variant, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Free tier content" }] }])
      create(:rich_content, entity: pro_variant, description: [{ "type" => "licenseKey" }])

      free_purchase = create(:purchase, link: @product, variant_attributes: [free_variant])
      pro_purchase = create(:purchase, link: @product, variant_attributes: [pro_variant])

      described_class.new.perform(@product.id)

      # @purchase1..3 have no variants, so they keep their licenses; the free
      # variant purchase is the only one skipped.
      expect(@product.licenses.map(&:purchase_id)).to match_array([@purchase1.id, @purchase2.id, @purchase3.id, pro_purchase.id])
      expect(@product.licenses.map(&:purchase_id)).not_to include(free_purchase.id)
    end
  end
end
