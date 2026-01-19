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

describe Subscription, "#resolve_vat_id" do
  let(:seller) { create(:user) }
  let(:product) { create(:subscription_product, user: seller) }

  before do
    create(:zip_tax_rate, country: "IT", zip_code: nil, state: nil, combined_rate: 0.22, is_seller_responsible: false)
  end

  it "prioritizes subscription's stored business_vat_id" do
    subscription = create(:subscription, link: product, business_vat_id: "SUBSCRIPTION_VAT")
    original_purchase = create(:free_purchase, is_original_subscription_purchase: true, link: product, subscription:)
    original_purchase.create_purchase_sales_tax_info!(business_vat_id: "PURCHASE_VAT", country_code: "IT")

    expect(subscription.resolve_vat_id).to eq "SUBSCRIPTION_VAT"
  end

  it "falls back to original purchase's sales tax info" do
    subscription = create(:subscription, link: product, business_vat_id: nil)
    original_purchase = create(:free_purchase, is_original_subscription_purchase: true, link: product, subscription:)
    original_purchase.create_purchase_sales_tax_info!(business_vat_id: "PURCHASE_VAT", country_code: "IT")

    expect(subscription.resolve_vat_id).to eq "PURCHASE_VAT"
  end

  it "falls back to original purchase's VAT refund" do
    subscription = create(:subscription, link: product, business_vat_id: nil)
    original_purchase = create(:free_purchase, is_original_subscription_purchase: true, link: product, subscription:, country: "Italy")
    create(:refund, purchase: original_purchase, gumroad_tax_cents: 22, amount_cents: 0, business_vat_id: "REFUND_VAT")

    expect(subscription.resolve_vat_id).to eq "REFUND_VAT"
  end

  it "falls back to any subscription purchase's VAT refund" do
    subscription = create(:subscription, link: product, business_vat_id: nil)
    create(:free_purchase, is_original_subscription_purchase: true, link: product, subscription:)
    recurring_purchase = create(:free_purchase, is_original_subscription_purchase: false, link: product, subscription:, country: "Italy")
    create(:refund, purchase: recurring_purchase, gumroad_tax_cents: 22, amount_cents: 0, business_vat_id: "RECURRING_REFUND_VAT")

    expect(subscription.resolve_vat_id).to eq "RECURRING_REFUND_VAT"
  end

  it "returns nil when no VAT ID exists" do
    subscription = create(:subscription, link: product, business_vat_id: nil)
    create(:free_purchase, is_original_subscription_purchase: true, link: product, subscription:)

    expect(subscription.resolve_vat_id).to be_nil
  end

  it "handles nil original_purchase gracefully" do
    subscription = create(:subscription, link: product, business_vat_id: nil)

    expect(subscription.resolve_vat_id).to be_nil
  end
end

describe Subscription, "#vat_id_from_any_subscription_purchase_refund" do
  let(:seller) { create(:user) }
  let(:product) { create(:subscription_product, user: seller) }

  before do
    create(:zip_tax_rate, country: "IT", zip_code: nil, state: nil, combined_rate: 0.22, is_seller_responsible: false)
  end

  it "returns the VAT ID from a VAT-only refund on any subscription purchase" do
    subscription = create(:subscription, link: product)
    create(:free_purchase, is_original_subscription_purchase: true, link: product, subscription:)
    recurring_purchase = create(:free_purchase, is_original_subscription_purchase: false, link: product,
                                                subscription:, country: "Italy")
    create(:refund, purchase: recurring_purchase, gumroad_tax_cents: 22, amount_cents: 0, business_vat_id: "DE987654321")

    expect(subscription.vat_id_from_any_subscription_purchase_refund).to eq "DE987654321"
  end

  it "returns nil when no VAT-only refunds with business_vat_id exist" do
    subscription = create(:subscription, link: product)
    create(:free_purchase, is_original_subscription_purchase: true, link: product, subscription:)

    expect(subscription.vat_id_from_any_subscription_purchase_refund).to be_nil
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

    expect(subscription.vat_id_from_any_subscription_purchase_refund).to eq "NEW_VAT_ID"
  end

  it "ignores refunds without business_vat_id" do
    subscription = create(:subscription, link: product)
    original_purchase = create(:free_purchase, is_original_subscription_purchase: true, link: product, subscription:)
    create(:refund, purchase: original_purchase, gumroad_tax_cents: 22, amount_cents: 0, business_vat_id: nil)

    expect(subscription.vat_id_from_any_subscription_purchase_refund).to be_nil
  end

  it "ignores non-VAT-only refunds (where amount_cents > 0)" do
    subscription = create(:subscription, link: product)
    original_purchase = create(:free_purchase, is_original_subscription_purchase: true, link: product, subscription:)
    create(:refund, purchase: original_purchase, gumroad_tax_cents: 22, amount_cents: 100, business_vat_id: "VAT_ID")

    expect(subscription.vat_id_from_any_subscription_purchase_refund).to be_nil
  end
end
