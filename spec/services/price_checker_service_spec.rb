# frozen_string_literal: true

require "spec_helper"

describe PriceCheckerService do
  let(:films_taxonomy) { Taxonomy.find_or_create_by(slug: "films") }
  let(:design_taxonomy) { Taxonomy.find_or_create_by(slug: "design") }
  let(:seller) { create(:named_seller) }
  let(:product) do
    create(
      :product,
      user: seller,
      name: "My film masterpiece",
      description: "A documentary about widgets in the wild.",
      price_cents: 1_500,
      taxonomy: films_taxonomy,
    )
  end

  before do
    Rails.cache.clear
    allow_any_instance_of(Link).to receive(:recommendable?).and_return(true)
    index_model_records(Link)
  end

  describe ".call" do
    context "with at least 10 same-taxonomy matches" do
      before do
        12.times do |i|
          create(
            :product,
            user: create(:user),
            name: "Film number #{i}",
            description: "A documentary similar to widgets.",
            price_cents: 500 + i * 250,
            taxonomy: films_taxonomy,
          )
        end
        index_model_records(Link)
      end

      it "returns ok with the with_taxonomy tier" do
        result = described_class.call(product:)

        expect(result[:status]).to eq("ok")
        expect(result[:tier]).to eq("with_taxonomy")
        expect(result[:match_count]).to be >= 10
        expect(result[:currency_code]).to eq("usd")
        expect(result[:current_price_cents]).to eq(1_500)
        expect(result[:summary][:median_cents]).to be > 0
        expect(result[:summary][:p25_cents]).to be <= result[:summary][:median_cents]
        expect(result[:summary][:p75_cents]).to be >= result[:summary][:median_cents]
        expect(result[:histogram][:bins]).not_to be_empty
        expect(result[:histogram][:interval_cents]).to be > 0
      end
    end

    context "when taxonomy has fewer than 10 matches but broader pool has at least 10" do
      before do
        4.times do |i|
          create(
            :product,
            user: create(:user),
            name: "Film #{i}",
            price_cents: 1_000 + i * 500,
            taxonomy: films_taxonomy,
          )
        end
        12.times do |i|
          create(
            :product,
            user: create(:user),
            name: "Design asset #{i}",
            description: "A design asset.",
            price_cents: 300 + i * 200,
            taxonomy: design_taxonomy,
          )
        end
        index_model_records(Link)
      end

      it "returns ok with the broadened tier" do
        result = described_class.call(product:)

        expect(result[:status]).to eq("ok")
        expect(result[:tier]).to eq("broadened")
        expect(result[:match_count]).to be >= 10
        expect(result[:taxonomy_label]).to be_nil
      end
    end

    context "with fewer than 10 matches even broadened" do
      before do
        2.times do |i|
          create(:product, user: create(:user), price_cents: 999 + i, taxonomy: films_taxonomy)
        end
        index_model_records(Link)
      end

      it "returns insufficient_data" do
        result = described_class.call(product:)

        expect(result[:status]).to eq("insufficient_data")
        expect(result[:tier]).to eq("insufficient")
        expect(result[:summary]).to be_nil
        expect(result[:histogram]).to be_nil
        expect(result[:current_price_cents]).to eq(1_500)
      end
    end

    context "when ES returns null percentiles even though there are enough matches" do
      before do
        12.times do |i|
          create(:product, user: create(:user), taxonomy: films_taxonomy, price_cents: 500 + i * 100)
        end
        index_model_records(Link)
      end

      it "cascades to insufficient_data instead of dereferencing nil" do
        results_double = double(total: 12)
        aggregations_double = double(
          dig: { "5.0" => nil, "25.0" => nil, "50.0" => nil, "75.0" => nil, "95.0" => nil }
        )
        response_double = double(results: results_double, aggregations: aggregations_double)
        allow(Link).to receive(:search).and_return(response_double)

        expect { described_class.call(product:) }.not_to raise_error
        result = described_class.call(product:)
        expect(result[:status]).to eq("insufficient_data")
        expect(result[:summary]).to be_nil
      end
    end

    context "exclusion rules" do
      before do
        create(:product, user: seller, price_cents: 5_000, taxonomy: films_taxonomy) # same seller
        create(:product, :is_subscription, user: create(:user), price_cents: 700, taxonomy: films_taxonomy) # subscription
        create(:product, :bundle, user: create(:user), price_cents: 800, taxonomy: films_taxonomy)
        create(:product, user: create(:user), customizable_price: true, price_cents: 900, taxonomy: films_taxonomy) # PWYW
        create(:product, user: create(:user), price_currency_type: "eur", price_cents: 1_100, taxonomy: films_taxonomy) # different currency
        create(:product, :is_physical, user: create(:user), price_cents: 1_200, taxonomy: films_taxonomy) # different native_type

        12.times do |i|
          create(:product, user: create(:user), taxonomy: films_taxonomy, price_cents: 600 + i * 100)
        end
        index_model_records(Link)
      end

      it "excludes own seller, the product itself, bundles, PWYW, different currency, different native_type" do
        result = described_class.call(product:)

        expect(result[:status]).to eq("ok")
        expect(result[:match_count]).to eq(12)
      end
    end

    context "caching" do
      before do
        12.times do |i|
          create(:product, user: create(:user), taxonomy: films_taxonomy, price_cents: 500 + i * 100)
        end
        index_model_records(Link)
      end

      it "caches the result and bypasses the cache when force_refresh is true" do
        expect(Link).to receive(:search).at_least(:twice).and_call_original

        described_class.call(product:)
        described_class.call(product:)
        described_class.call(product:, force_refresh: true)
      end

      it "stores the result under a stable cache key" do
        first_result = described_class.call(product:)
        expect(Rails.cache.read("price_checker:v1:#{product.id}:#{Digest::MD5.hexdigest([product.name, product.description.to_s.first(500), product.native_type, product.is_recurring_billing, product.price_currency_type, product.taxonomy_id].join('|'))}")).to eq(first_result)
      end
    end
  end
end
