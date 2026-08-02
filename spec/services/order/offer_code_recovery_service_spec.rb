# frozen_string_literal: true

require "spec_helper"

describe Order::OfferCodeRecoveryService do
  let(:seller) { create(:user) }
  let(:product_1) { create(:product, user: seller, price_cents: 10_00) }
  let(:product_2) { create(:product, user: seller, price_cents: 20_00) }
  let(:offer_code) do
    create(:offer_code, user: seller, products: [product_1, product_2], amount_cents: 1_00, once_per_cart: true)
  end

  it "returns every eligible line when an unallocated purchase fails" do
    params = {
      email: "buyer@example.com",
      browser_guid: SecureRandom.uuid,
      ip_address: "0.0.0.0",
      line_items: [
        { uid: "first", permalink: product_1.unique_permalink, perceived_price_cents: 9_00, quantity: 1,
          discount_code: offer_code.code },
        { uid: "second", permalink: product_2.unique_permalink, perceived_price_cents: 20_00, quantity: 1,
          discount_code: offer_code.code },
      ],
    }
    order, purchase_responses = Order::CreateService.new(params:).perform
    expect(purchase_responses).to be_empty
    purchases = order.purchases.order(:id)
    expect(purchases.map(&:offer_code_id)).to eq([offer_code.id, nil])

    result = described_class.new(order:, failed_purchases: [purchases.second]).perform

    expect(result.one?).to be(true)
    expect(result.first[:code]).to eq(offer_code.code)
    expect(result.first[:products].keys).to contain_exactly(product_1.unique_permalink, product_2.unique_permalink)
  end

  it "merges product maps for responses that share a normalized code" do
    merged = described_class.merge_responses(
      [{ code: "SAVE", products: { product_1.unique_permalink => { cents: 100 } } }],
      [{ code: " save ", products: { product_2.unique_permalink => { cents: 0 } } }],
    )

    expect(merged.one?).to be(true)
    expect(merged.first[:code]).to eq("SAVE")
    expect(merged.first[:products].keys).to contain_exactly(product_1.unique_permalink, product_2.unique_permalink)
  end
end
