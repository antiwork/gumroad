# frozen_string_literal: true

require "spec_helper"

describe SellerInFlightSales do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, name: "Pending product", price_cents: 12_00) }
  let(:service) { described_class.new(seller) }

  def in_flight(**attrs)
    create(:purchase_in_progress, link: product, seller:, price_cents: 12_00, stripe_status: "processing", **attrs)
  end

  it "lists an unfinished sale with processor evidence and hides an abandoned checkout" do
    visible = in_flight(email: "buyer@example.com", full_name: "Buyer")
    create(
      :purchase_in_progress,
      link: product,
      seller:,
      price_cents: 0,
      stripe_transaction_id: nil,
      stripe_fingerprint: nil,
      charge_processor_id: nil,
      merchant_account: nil,
      stripe_status: nil,
      paypal_order_id: nil
    )
    create(:purchase, link: product, seller:)

    expect(service.records.map(&:id)).to eq([visible.id])
    expect(service.count).to eq(1)
    expect(visible.seller_visible_in_flight?).to eq(true)
  end

  it "keeps the unfinished sale out of the completed count for its product" do
    in_flight
    expect(service.counts_by_product([product.id])).to eq(product.id => 1)
    expect(product.processing_sales_count).to eq(1)
  end

  it "keeps the newest unfinished sales when the list is capped" do
    stub_const("SellerInFlightSales::MAX_ROWS", 1)
    in_flight(created_at: 2.days.ago)
    newest = in_flight(created_at: 1.hour.ago)

    expect(service.records.map(&:id)).to eq([newest.id])
  end

  it "matches a selected product or a selected variant" do
    other = create(:product, user: seller)
    variant = create(:variant, variant_category: create(:variant_category, link: other))
    by_product = in_flight
    by_variant = in_flight(link: other)
    by_variant.variant_attributes << variant

    expect(service.records(products: [product], variants: [variant]).map(&:id)).to contain_exactly(by_product.id, by_variant.id)
  end

  it "hides a prepared payment intent the buyer has not confirmed" do
    prepared = create(
      :purchase_in_progress,
      link: product,
      seller:,
      price_cents: 12_00,
      stripe_transaction_id: nil,
      stripe_status: nil,
      paypal_order_id: nil
    )
    prepared.create_processor_payment_intent!(intent_id: "pi_prepared")

    expect(prepared.seller_visible_in_flight?).to eq(false)
    expect(service.records).to eq([])
  end

  it "does not treat a successful sale as processing" do
    purchase = create(:purchase, link: product, seller:)
    expect(purchase.seller_visible_in_flight?).to eq(false)
    expect(service.count).to eq(0)
  end
end
