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

  it "preserves eligible duplicate-product lines during recovery" do
    offer_code.update!(minimum_quantity: 2)
    eligible_purchase = create(:failed_purchase, link: product_1, seller:, offer_code:, quantity: 2,
                                                 price_cents: product_1.price_cents * 2)
    eligible_purchase.create_purchase_offer_code_discount!(
      offer_code:,
      offer_code_amount: offer_code.amount_cents,
      offer_code_is_percent: false,
      once_per_cart: true,
      pre_discount_minimum_price_cents: product_1.price_cents
    )
    ineligible_purchase = create(:failed_purchase, link: product_1, seller:, quantity: 1)
    order = create(:order)
    order.purchases << [eligible_purchase, ineligible_purchase]

    result = described_class.new(order:, failed_purchases: [eligible_purchase]).perform

    expect(result).to contain_exactly(
      code: offer_code.code,
      products: { product_1.unique_permalink => include(once_per_cart: true, cents: offer_code.amount_cents) }
    )
  end

  it "does not recover a capped code after another line in the order succeeds" do
    offer_code.update!(max_purchase_count: 2)
    prior_purchase = create(:purchase, link: product_1, seller:, offer_code:)
    prior_purchase.create_purchase_offer_code_discount!(
      offer_code:,
      offer_code_amount: offer_code.amount_cents,
      offer_code_is_percent: false,
      once_per_cart: true,
      once_per_cart_allocation_id: SecureRandom.uuid,
      pre_discount_minimum_price_cents: product_1.price_cents
    )

    allocation_id = SecureRandom.uuid
    successful_purchase = create(:purchase, link: product_1, seller:, offer_code:)
    successful_purchase.create_purchase_offer_code_discount!(
      offer_code:,
      offer_code_amount: offer_code.amount_cents,
      offer_code_is_percent: false,
      once_per_cart: true,
      once_per_cart_allocation_id: allocation_id,
      pre_discount_minimum_price_cents: product_1.price_cents
    )
    failed_purchase = create(:failed_purchase, link: product_2, seller:)
    order = create(:order)
    order.purchases << [successful_purchase, failed_purchase]

    result = described_class.new(order:, failed_purchases: [failed_purchase]).perform

    expect(result).to be_empty
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
