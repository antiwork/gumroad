# frozen_string_literal: true

require "spec_helper"

describe ProductOfferCodeIndexingService do
  let(:seller) { create(:user) }
  let(:usd) { create(:product, user: seller, price_currency_type: "usd", price_cents: 1000) }
  let(:eur) { create(:product, user: seller, price_currency_type: "eur", price_cents: 1000) }

  def indexed_codes(product)
    product.__elasticsearch__.client.get(index: Link.index_name, id: product.id).dig("_source", "offer_codes")
  end

  it "matches the existing search value for currencies, exclusions, deleted codes and mixed associations" do
    products = [usd, eur, create(:product)]
    create(:offer_code, user: seller, products: [usd], code: "SPECIFIC")
    create(:universal_offer_code, user: seller, code: "USD", currency_type: "usd")
    create(:universal_offer_code, user: seller, code: "EUR", currency_type: "eur")
    create(:universal_offer_code, user: seller, code: "PERCENT", currency_type: nil, amount_cents: nil, amount_percentage: 10)
    create(:universal_offer_code, user: seller, code: "EXCLUDED", excluded_products: [usd])
    create(:universal_offer_code, user: seller, code: "DELETED", deleted_at: Time.current)
    described_class.new(products).perform
    products.each do |product|
      expect(indexed_codes(product)).to eq(product.reload.build_search_update(["offer_codes"])["offer_codes"])
    end
  end

  it "preserves the cap and creation ordering" do
    stub_const("Product::Searchable::MAX_OFFER_CODES_IN_INDEX", 2)
    3.times { |i| create(:universal_offer_code, user: seller, code: "CODE#{i}", created_at: i.days.ago) }
    described_class.new([usd]).perform
    expect(indexed_codes(usd)).to eq(["CODE1", "CODE0"])
  end

  it "loads seller-wide codes once per batch instead of once per product" do
    products = create_list(:product, 25, user: seller)
    create(:universal_offer_code, user: seller)
    statements = []
    subscriber = ->(*args) { statements << args.last[:sql] if args.last[:sql].match?(/SELECT.*offer_codes/i) }
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      described_class.new(products).perform
    end
    expect(statements.size).to eq(3)
    expect(statements.grep(/NOT EXISTS/)).to be_empty
    puts "offer-code batch: products=#{products.size}, offer-code SELECTs=#{statements.size}, per-product universal lookups=0"
  end
end
