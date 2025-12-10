# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillSubscriptionVatIds do
  describe ".process" do
    let(:seller) { create(:user) }
    let(:product) { create(:subscription_product, user: seller) }

    before do
      create(:zip_tax_rate, country: "IT", zip_code: nil, state: nil, combined_rate: 0.22, is_seller_responsible: false)
    end

    it "backfills VAT ID from original purchase's sales tax info" do
      subscription = create(:subscription, link: product, business_vat_id: nil)
      original_purchase = create(:purchase, is_original_subscription_purchase: true, link: product,
                                            subscription:, purchase_state: "successful",
                                            full_name: "gum stein", ip_address: "2.47.255.255", country: "Italy")
      original_purchase.create_purchase_sales_tax_info!(business_vat_id: "IE6388047V", country_code: "IT")

      expect { described_class.process }.to change { subscription.reload.business_vat_id }.from(nil).to("IE6388047V")
    end

    it "backfills VAT ID from VAT refund on any subscription purchase" do
      subscription = create(:subscription, link: product, business_vat_id: nil)
      original_purchase = create(:purchase, is_original_subscription_purchase: true, link: product,
                                            subscription:, purchase_state: "successful",
                                            full_name: "gum stein", ip_address: "2.47.255.255", country: "Italy")
      recurring_purchase = create(:purchase, is_original_subscription_purchase: false, link: product,
                                             subscription:, purchase_state: "successful",
                                             full_name: "gum stein", ip_address: "2.47.255.255", country: "Italy")
      create(:refund, purchase: recurring_purchase, gumroad_tax_cents: 22, amount_cents: 0, business_vat_id: "IE6388047V")

      expect { described_class.process }.to change { subscription.reload.business_vat_id }.from(nil).to("IE6388047V")
    end

    it "does not update subscriptions that already have a VAT ID" do
      subscription = create(:subscription, link: product, business_vat_id: "DE123456789")
      original_purchase = create(:purchase, is_original_subscription_purchase: true, link: product,
                                            subscription:, purchase_state: "successful")
      original_purchase.create_purchase_sales_tax_info!(business_vat_id: "IE6388047V", country_code: "IT")

      expect { described_class.process }.not_to change { subscription.reload.business_vat_id }
    end

    it "skips subscriptions without any VAT ID source" do
      subscription = create(:subscription, link: product, business_vat_id: nil)
      create(:purchase, is_original_subscription_purchase: true, link: product,
                        subscription:, purchase_state: "successful")

      expect { described_class.process }.not_to change { subscription.reload.business_vat_id }
    end

    it "returns count of backfilled subscriptions" do
      subscription1 = create(:subscription, link: product, business_vat_id: nil)
      subscription2 = create(:subscription, link: product, business_vat_id: nil)

      original_purchase1 = create(:purchase, is_original_subscription_purchase: true, link: product,
                                             subscription: subscription1, purchase_state: "successful")
      original_purchase1.create_purchase_sales_tax_info!(business_vat_id: "IE6388047V", country_code: "IT")

      original_purchase2 = create(:purchase, is_original_subscription_purchase: true, link: product,
                                             subscription: subscription2, purchase_state: "successful")
      original_purchase2.create_purchase_sales_tax_info!(business_vat_id: "DE123456789", country_code: "DE")

      count = described_class.process

      expect(count).to eq 2
    end
  end
end
