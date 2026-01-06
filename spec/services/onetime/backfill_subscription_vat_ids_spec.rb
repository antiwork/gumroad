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
      original_purchase = create(:free_purchase, is_original_subscription_purchase: true, link: product,
                                                 subscription:, full_name: "gum stein", country: "Italy")
      original_purchase.create_purchase_sales_tax_info!(business_vat_id: "IE6388047V", country_code: "IT")

      expect { described_class.process }.to change { subscription.reload.business_vat_id }.from(nil).to("IE6388047V")
    end

    it "backfills VAT ID from VAT refund on any subscription purchase" do
      subscription = create(:subscription, link: product, business_vat_id: nil)
      create(:free_purchase, is_original_subscription_purchase: true, link: product, subscription:)
      recurring_purchase = create(:free_purchase, is_original_subscription_purchase: false, link: product,
                                                  subscription:, country: "Italy")
      create(:refund, purchase: recurring_purchase, gumroad_tax_cents: 22, amount_cents: 0, business_vat_id: "IE6388047V")

      expect { described_class.process }.to change { subscription.reload.business_vat_id }.from(nil).to("IE6388047V")
    end

    it "does not update subscriptions that already have a VAT ID" do
      subscription = create(:subscription, link: product, business_vat_id: "DE123456789")
      original_purchase = create(:free_purchase, is_original_subscription_purchase: true, link: product, subscription:)
      original_purchase.create_purchase_sales_tax_info!(business_vat_id: "IE6388047V", country_code: "IT")

      expect { described_class.process }.not_to change { subscription.reload.business_vat_id }
    end

    it "skips subscriptions without any VAT ID source" do
      subscription = create(:subscription, link: product, business_vat_id: nil)
      create(:free_purchase, is_original_subscription_purchase: true, link: product, subscription:)

      expect { described_class.process }.not_to change { subscription.reload.business_vat_id }
    end

    it "returns count of backfilled subscriptions" do
      subscription1 = create(:subscription, link: product, business_vat_id: nil)
      subscription2 = create(:subscription, link: product, business_vat_id: nil)

      original_purchase1 = create(:free_purchase, is_original_subscription_purchase: true, link: product,
                                                  subscription: subscription1)
      original_purchase1.create_purchase_sales_tax_info!(business_vat_id: "IE6388047V", country_code: "IT")

      original_purchase2 = create(:free_purchase, is_original_subscription_purchase: true, link: product,
                                                  subscription: subscription2)
      original_purchase2.create_purchase_sales_tax_info!(business_vat_id: "DE123456789", country_code: "DE")

      count = described_class.process

      expect(count).to eq 2
    end

    it "continues processing if one subscription fails" do
      subscription1 = create(:subscription, link: product, business_vat_id: nil)
      subscription2 = create(:subscription, link: product, business_vat_id: nil)

      original_purchase1 = create(:free_purchase, is_original_subscription_purchase: true, link: product,
                                                  subscription: subscription1)
      original_purchase1.create_purchase_sales_tax_info!(business_vat_id: "IE6388047V", country_code: "IT")

      original_purchase2 = create(:free_purchase, is_original_subscription_purchase: true, link: product,
                                                  subscription: subscription2)
      original_purchase2.create_purchase_sales_tax_info!(business_vat_id: "DE123456789", country_code: "DE")

      call_count = 0
      allow_any_instance_of(Subscription).to receive(:update!).and_wrap_original do |method, *args|
        call_count += 1
        raise StandardError.new("Test error") if call_count == 1
        method.call(*args)
      end

      expect { described_class.process }.not_to raise_error
      expect(subscription2.reload.business_vat_id).to eq "DE123456789"
    end
  end
end
