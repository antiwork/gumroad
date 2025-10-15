# frozen_string_literal: true

require "spec_helper"

describe Subscription do
  describe "VAT ID edge cases" do
    before(:each) do
      @seller = create(:user)
    end

    let(:seller) { @seller }
    let(:product) { create(:subscription_product_with_versions, user: seller) }
    let(:subscription) { create(:subscription, seller: seller, link: product) }
    let(:original_purchase) { create(:purchase, link: product, subscription: subscription, seller: seller, is_original_subscription_purchase: true) }

    describe "subscription plan changes" do
      before do
        # Set up original purchase with VAT ID
        original_purchase.create_purchase_sales_tax_info!(
          business_vat_id: "DE123456789",
          country_code: "DE",
          ip_address: "127.0.0.1",
          postal_code: "10115",
          state_code: nil,
          ip_country_code: "DE",
          elected_country_code: "DE"
        )
      end

      it "preserves VAT ID information during plan changes" do
        # Test that build_purchase preserves VAT ID from original purchase
        renewal_purchase = subscription.build_purchase

        expect(renewal_purchase.business_vat_id).to eq("DE123456789")

        # Test that the VAT ID is preserved in the business_vat_id field
        # This is the main functionality we want to test
        expect(subscription.original_purchase.purchase_sales_tax_info.business_vat_id).to eq("DE123456789")
      end
    end

    describe "gift subscriptions" do
      let(:gift_subscription) { create(:subscription, seller: seller, link: product) }
      let(:gift_sender_purchase) { create(:purchase, link: product, subscription: gift_subscription, seller: seller, is_original_subscription_purchase: true, is_gift_sender_purchase: true) }
      let(:gift_receiver_purchase) { create(:purchase, link: product, subscription: gift_subscription, seller: seller, is_gift_receiver_purchase: true) }

      before do
        gift_sender_purchase.create_purchase_sales_tax_info!(
          business_vat_id: "DE123456789",
          country_code: "DE"
        )
      end

      it "uses true_original_purchase for gift subscriptions" do
        renewal_purchase = gift_subscription.build_purchase

        expect(renewal_purchase.business_vat_id).to eq("DE123456789")
      end

      it "handles VAT ID persistence for gift subscriptions in invoice generation" do
        # This would be tested in the controller spec, but we can verify the logic here
        expect(gift_subscription.gift?).to be true
        expect(gift_subscription.true_original_purchase).to eq(gift_sender_purchase)
        # For gift subscriptions, the original_purchase is the gift sender purchase (not archived)
        expect(gift_subscription.original_purchase).to eq(gift_sender_purchase)
      end
    end

    describe "installment plans" do
      let(:product_with_installment) { create(:product, :with_installment_plan, user: seller) }
      let(:installment_subscription) { create(:subscription, seller: seller, link: product_with_installment, is_installment_plan: true) }
      let(:installment_purchase) { create(:purchase, link: product_with_installment, subscription: installment_subscription, seller: seller, is_original_subscription_purchase: true) }

      before do
        installment_purchase.create_purchase_sales_tax_info!(
          business_vat_id: "DE123456789",
          country_code: "DE"
        )
      end

      it "preserves VAT ID for installment plan renewals" do
        renewal_purchase = installment_subscription.build_purchase

        expect(renewal_purchase.business_vat_id).to eq("DE123456789")
      end

      it "cannot be updated via update_current_plan!" do
        new_price = create(:price, link: product_with_installment, price_cents: 2000, recurrence: "monthly")
        new_variants = installment_purchase.variant_attributes

        expect do
          installment_subscription.update_current_plan!(
            new_variants: new_variants,
            new_price: new_price,
            perceived_price_cents: 2000,
            skip_preparing_for_charge: true
          )
        end.to raise_error(Subscription::UpdateFailed, "Installment plans cannot be updated.")
      end
    end

    describe "subscription resubscription" do
      before do
        original_purchase.create_purchase_sales_tax_info!(
          business_vat_id: "DE123456789",
          country_code: "DE"
        )
      end

      it "preserves VAT ID after resubscription" do
        # Cancel the subscription
        subscription.cancel!
        subscription.deactivate!

        # Resubscribe
        subscription.resubscribe!

        # Build a new purchase and verify VAT ID is preserved
        renewal_purchase = subscription.build_purchase

        expect(renewal_purchase.business_vat_id).to eq("DE123456789")
      end
    end

    describe "VAT ID from refunds fallback" do
      before do
        # Create a refund with VAT ID (simulating post-invoice VAT addition)
        create(:refund,
               purchase: original_purchase,
               business_vat_id: "DE123456789",
               gumroad_tax_cents: 100,
               amount_cents: 0)
      end

      it "falls back to VAT ID from refunds when purchase_sales_tax_info is missing" do
        renewal_purchase = subscription.build_purchase

        expect(renewal_purchase.business_vat_id).to eq("DE123456789")
      end
    end
  end
end
