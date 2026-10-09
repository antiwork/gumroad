# frozen_string_literal: true

require "spec_helper"

describe "Purchase#minimum_paid_price_cents with PPP and installments" do
  let(:product) { create(:product, price_cents: 2800, purchasing_power_parity_disabled: false) }
  let!(:installment_plan) { create(:product_installment_plan, link: product, number_of_installments: 2, recurrence: "monthly") }
  let(:purchase) do
    build(:purchase, link: product, is_installment_payment: true, installment_plan: installment_plan, is_purchasing_power_parity_discounted: true, ip_country: "Kazakhstan")
  end

  before do
    product.user.update!(purchasing_power_parity_enabled: true)
    allow_any_instance_of(Purchase).to receive(:purchasing_power_parity_factor).and_return(0.7)
  end

  it "splits the rounded discounted total so the first installment matches the client" do
    expect(2800 * 0.7).to eq(1959.9999999999998)
    expect(purchase.minimum_paid_price_cents).to eq(980)
  end

  it "accepts the client's perceived first installment" do
    purchase.perceived_price_cents = 980
    expect(purchase.send(:perceived_price_equals_link_price?)).to eq(true)
  end
end
