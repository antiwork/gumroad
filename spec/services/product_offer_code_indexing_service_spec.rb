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

  it "continues past a missing document but raises on a missing index" do
    products = [usd, eur]
    usd.__elasticsearch__.delete_document
    expect { described_class.new(products).perform }.not_to raise_error
    expect(indexed_codes(eur)).to eq([])
    expect(indexed_codes(usd)).to eq([])
    allow(eur.__elasticsearch__).to receive(:update_document_attributes).and_raise(Elasticsearch::Transport::Transport::Errors::NotFound, "index_not_found_exception")
    expect { described_class.new([eur]).perform }.to raise_error(Elasticsearch::Transport::Transport::Errors::NotFound, /index_not_found/)
  end

  it "raises without creating or acknowledging an absent index" do
    product = usd
    original_name = Link.index_name
    allow(Link).to receive(:index_name).and_return("missing-offer-code-index-#{SecureRandom.hex(8)}")
    expect { described_class.new([product]).perform }.to raise_error(Elasticsearch::Transport::Transport::Errors::NotFound, /index_not_found/)
    expect(Link.__elasticsearch__.client.indices.exists?(index: Link.index_name)).to be(false)
    expect(Link.__elasticsearch__.client.indices.exists?(index: original_name)).to be(true)
  end

  it "matches the existing capped value when timestamps tie across both sources" do
    freeze_time
    product = usd
    create(:offer_code, user: seller, products: [product], code: "SPECIFIC1")
    create(:universal_offer_code, user: seller, code: "UNIVERSAL1")
    create(:offer_code, user: seller, products: [product], code: "SPECIFIC2")
    create(:universal_offer_code, user: seller, code: "UNIVERSAL2")
    stub_const("Product::Searchable::MAX_OFFER_CODES_IN_INDEX", 2)
    expected = product.reload.build_search_update(["offer_codes"])["offer_codes"]
    described_class.new([product]).perform
    expect(indexed_codes(product)).to eq(expected)
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
      products.each { _1.reload.build_search_update(["offer_codes"]) }
    end
    before_universal = statements.grep(/NOT EXISTS/).size
    statements.clear
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      described_class.new(products).perform
    end
    expect(before_universal).to eq(products.size)
    expect(statements.size).to eq(3)
    expect(statements.grep(/NOT EXISTS/)).to be_empty
  end

  it "reports a single product failure and keeps indexing the rest of the batch" do
    products = [usd, eur]
    create(:universal_offer_code, user: seller, code: "KEEP", currency_type: nil, amount_cents: nil, amount_percentage: 10)
    allow(usd.__elasticsearch__).to receive(:update_document_attributes).and_raise(Elasticsearch::Transport::Transport::Errors::BadRequest, "mapper_parsing_exception")
    expect(ErrorNotifier).to receive(:notify).with(
      an_instance_of(Elasticsearch::Transport::Transport::Errors::BadRequest),
      product_id: usd.id,
      user_id: seller.id
    )
    expect { described_class.new(products).perform }.not_to raise_error
    expect(indexed_codes(eur)).to eq(["KEEP"])
  end

  it "reports a missing-document fallback permanent failure without stopping later products" do
    products = [usd, eur]
    create(:universal_offer_code, user: seller, code: "KEEP", currency_type: nil, amount_cents: nil, amount_percentage: 10)
    usd.__elasticsearch__.delete_document
    allow(usd.__elasticsearch__).to receive(:index_document).and_raise(Elasticsearch::Transport::Transport::Errors::BadRequest, "mapper_parsing_exception")
    expect(ErrorNotifier).to receive(:notify).with(
      an_instance_of(Elasticsearch::Transport::Transport::Errors::BadRequest),
      product_id: usd.id,
      user_id: seller.id
    )
    expect { described_class.new(products).perform }.not_to raise_error
    expect(indexed_codes(eur)).to eq(["KEEP"])
  end

  it "re-raises retryable transport failures so the seller scan stays pinned" do
    allow(usd.__elasticsearch__).to receive(:update_document_attributes).and_raise(Faraday::TimeoutError)
    expect(ErrorNotifier).not_to receive(:notify)
    expect { described_class.new([usd, eur]).perform }.to raise_error(Faraday::TimeoutError)
  end
end
