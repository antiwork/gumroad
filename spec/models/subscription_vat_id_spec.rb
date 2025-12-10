# frozen_string_literal: true

require "spec_helper"

describe Subscription, "#update_business_vat_id!" do
  let(:seller) { create(:user) }
  let(:product) { create(:subscription_product, user: seller) }
  let(:subscription) { create(:subscription, link: product, business_vat_id: nil) }

  it "updates subscription's business_vat_id when not already set" do
    subscription.update_business_vat_id!("IE6388047V")

    expect(subscription.reload.business_vat_id).to eq "IE6388047V"
  end

  it "does not update subscription's business_vat_id when already set" do
    subscription.update!(business_vat_id: "DE123456789")

    subscription.update_business_vat_id!("IE6388047V")

    expect(subscription.reload.business_vat_id).to eq "DE123456789"
  end

  it "does not update subscription's business_vat_id when nil is provided" do
    subscription.update_business_vat_id!(nil)

    expect(subscription.reload.business_vat_id).to be_nil
  end

  it "does not update subscription's business_vat_id when empty string is provided" do
    subscription.update_business_vat_id!("")

    expect(subscription.reload.business_vat_id).to be_nil
  end
end

describe Subscription, "VAT ID lookup methods" do
  let(:seller) { create(:user) }
  let(:product) { create(:subscription_product, user: seller) }

  before do
    create(:zip_tax_rate, country: "IT", zip_code: nil, state: nil, combined_rate: 0.22, is_seller_responsible: false)
  end

  describe "#vat_id_from_original_purchase_refund" do
    it "returns the VAT ID from the most recent VAT-only refund on original purchase" do
      subscription = create(:subscription, link: product)
      original_purchase = create(:free_purchase, is_original_subscription_purchase: true, link: product,
                                                 subscription:, full_name: "gum stein", country: "Italy")
      create(:refund, purchase: original_purchase, gumroad_tax_cents: 22, amount_cents: 0, business_vat_id: "IE6388047V")

      result = subscription.send(:vat_id_from_original_purchase_refund)
      expect(result).to eq "IE6388047V"
    end

    it "returns nil when no VAT-only refunds exist" do
      subscription = create(:subscription, link: product)
      create(:free_purchase, is_original_subscription_purchase: true, link: product, subscription:)

      result = subscription.send(:vat_id_from_original_purchase_refund)
      expect(result).to be_nil
    end

    it "returns nil when refunds exist but don't have a business_vat_id" do
      subscription = create(:subscription, link: product)
      original_purchase = create(:free_purchase, is_original_subscription_purchase: true, link: product, subscription:)
      create(:refund, purchase: original_purchase, gumroad_tax_cents: 22, amount_cents: 0, business_vat_id: nil)

      result = subscription.send(:vat_id_from_original_purchase_refund)
      expect(result).to be_nil
    end
  end

  describe "#vat_id_from_any_subscription_purchase_refund" do
    it "returns the VAT ID from a VAT-only refund on any subscription purchase" do
      subscription = create(:subscription, link: product)
      create(:free_purchase, is_original_subscription_purchase: true, link: product, subscription:)
      recurring_purchase = create(:free_purchase, is_original_subscription_purchase: false, link: product,
                                                  subscription:, country: "Italy")
      create(:refund, purchase: recurring_purchase, gumroad_tax_cents: 22, amount_cents: 0, business_vat_id: "DE987654321")

      result = subscription.send(:vat_id_from_any_subscription_purchase_refund)
      expect(result).to eq "DE987654321"
    end

    it "returns nil when no VAT-only refunds with business_vat_id exist" do
      subscription = create(:subscription, link: product)
      create(:free_purchase, is_original_subscription_purchase: true, link: product, subscription:)

      result = subscription.send(:vat_id_from_any_subscription_purchase_refund)
      expect(result).to be_nil
    end

    it "returns the most recent VAT ID when multiple refunds exist" do
      subscription = create(:subscription, link: product)
      create(:free_purchase, is_original_subscription_purchase: true, link: product, subscription:)
      recurring_purchase1 = create(:free_purchase, is_original_subscription_purchase: false, link: product,
                                                   subscription:, country: "Italy")
      recurring_purchase2 = create(:free_purchase, is_original_subscription_purchase: false, link: product,
                                                   subscription:, country: "Italy")
      create(:refund, purchase: recurring_purchase1, gumroad_tax_cents: 22, amount_cents: 0,
                      business_vat_id: "OLD_VAT_ID", created_at: 2.days.ago)
      create(:refund, purchase: recurring_purchase2, gumroad_tax_cents: 22, amount_cents: 0,
                      business_vat_id: "NEW_VAT_ID", created_at: 1.day.ago)

      result = subscription.send(:vat_id_from_any_subscription_purchase_refund)
      expect(result).to eq "NEW_VAT_ID"
    end
  end
end
