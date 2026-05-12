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
    context "with at least 5 same-taxonomy matches" do
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
        expect(result[:match_count]).to be >= 5
        expect(result[:currency_code]).to eq("usd")
        expect(result[:current_price_cents]).to eq(1_500)
        expect(result[:summary][:median_cents]).to be > 0
        expect(result[:summary][:p25_cents]).to be <= result[:summary][:median_cents]
        expect(result[:summary][:p75_cents]).to be >= result[:summary][:median_cents]
        expect(result[:histogram][:bins]).not_to be_empty
        expect(result[:histogram][:interval_cents]).to be > 0
      end
    end

    context "when taxonomy has fewer than 5 matches but broader pool has at least 5" do
      before do
        2.times do |i|
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
            name: "Documentary widgets #{i}",
            description: "A documentary about widgets.",
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
        expect(result[:match_count]).to be >= 5
        expect(result[:taxonomy_label]).to be_nil
      end
    end

    context "with fewer than 5 matches even broadened" do
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

    context "with override fields" do
      before do
        12.times do |i|
          create(
            :product,
            user: create(:user),
            taxonomy: design_taxonomy,
            price_cents: 4_000 + i * 200,
            name: "Design template kit #{i}",
            description: "A design template for designers.",
          )
        end
        index_model_records(Link)
      end

      it "uses override taxonomy_id, name, and description for matching" do
        result = described_class.call(
          product:,
          overrides: {
            taxonomy_id: design_taxonomy.id,
            name: "Design template kit",
            description: "A design template for designers.",
          },
        )

        expect(result[:status]).to eq("ok")
        expect(result[:tier]).to eq("with_taxonomy")
        expect(result[:summary][:median_cents]).to be_between(4_000, 6_400)
      end
    end

    context "when relevance filter excludes unrelated products" do
      before do
        12.times do |i|
          create(
            :product,
            user: create(:user),
            name: "Quantum widget #{i}",
            description: "Crystal latte tutorial.",
            price_cents: 500 + i * 100,
            taxonomy: films_taxonomy,
          )
        end
        index_model_records(Link)
      end

      it "treats unrelated names as insufficient_data" do
        result = described_class.call(product:)

        expect(result[:status]).to eq("insufficient_data")
        expect(result[:tier]).to eq("insufficient")
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
        response_double = double(results: results_double, aggregations: aggregations_double, response: { "timed_out" => false })
        allow(Link).to receive(:search).and_return(response_double)

        expect { described_class.call(product:) }.not_to raise_error
        result = described_class.call(product:)
        expect(result[:status]).to eq("insufficient_data")
        expect(result[:summary]).to be_nil
      end
    end

    context "exclusion rules" do
      let(:matching_attrs) do
        { name: "Film masterpiece", description: "A documentary about widgets in the wild." }
      end

      before do
        create(:product, **matching_attrs, user: seller, price_cents: 5_000, taxonomy: films_taxonomy) # same seller
        create(:product, :is_subscription, **matching_attrs, user: create(:user), price_cents: 700, taxonomy: films_taxonomy)
        create(:product, :bundle, user: create(:user), price_cents: 800, taxonomy: films_taxonomy)
        create(:product, **matching_attrs, user: create(:user), customizable_price: true, price_cents: 900, taxonomy: films_taxonomy) # PWYW
        create(:product, **matching_attrs, user: create(:user), price_currency_type: "eur", price_cents: 1_100, taxonomy: films_taxonomy)
        create(:product, :is_physical, **matching_attrs, user: create(:user), price_cents: 1_200, taxonomy: films_taxonomy)

        12.times do |i|
          create(
            :product,
            user: create(:user),
            taxonomy: films_taxonomy,
            price_cents: 600 + i * 100,
            name: "Film masterpiece #{i}",
            description: "A documentary about widgets in the wild.",
          )
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
          create(
            :product,
            user: create(:user),
            taxonomy: films_taxonomy,
            price_cents: 500 + i * 100,
            name: "Film masterpiece #{i}",
            description: "A documentary about widgets in the wild.",
          )
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
        expected_fingerprint = Digest::MD5.hexdigest([product.name, Digest::MD5.hexdigest(product.description.to_s.first(1_000)), product.native_type, product.is_recurring_billing, product.price_currency_type, product.taxonomy_id].join("|"))
        expect(Rails.cache.read("price_checker:v3:#{product.id}:#{expected_fingerprint}")).to eq(first_result)
      end

      it "uses different cache keys for different descriptions so a description edit busts the cache" do
        service_a = described_class.new(product:, overrides: { description: "First description content" })
        service_b = described_class.new(product:, overrides: { description: "Completely different second description content" })

        expect(service_a.send(:cache_key)).not_to eq(service_b.send(:cache_key))
      end

      it "uses different cache keys for different currencies so a currency edit busts the cache" do
        service_a = described_class.new(product:, overrides: { currency_code: "usd" })
        service_b = described_class.new(product:, overrides: { currency_code: "eur" })

        expect(service_a.send(:cache_key)).not_to eq(service_b.send(:cache_key))
      end
    end

    context "with a currency override" do
      it "returns the effective currency in the response, not the saved one" do
        result = described_class.call(product:, overrides: { currency_code: "eur" })

        expect(result[:currency_code]).to eq("eur")
      end
    end

    context "when the product is in the 'other' taxonomy" do
      let(:other_taxonomy) { Taxonomy.find_or_create_by(slug: "other") }
      let(:product) do
        create(
          :product,
          user: seller,
          name: "My film masterpiece",
          description: "A documentary about widgets in the wild.",
          price_cents: 1_500,
          taxonomy: other_taxonomy,
        )
      end

      before do
        12.times do |i|
          create(
            :product,
            user: create(:user),
            taxonomy: other_taxonomy,
            price_cents: 500 + i * 100,
            name: "Film masterpiece #{i}",
            description: "A documentary about widgets in the wild.",
          )
        end
        index_model_records(Link)
      end

      it "returns a nil taxonomy_label so the UI does not show a misleading badge" do
        result = described_class.call(product:)

        expect(result[:status]).to eq("ok")
        expect(result[:tier]).to eq("with_taxonomy")
        expect(result[:taxonomy_label]).to be_nil
      end
    end

    context "when an ES query times out" do
      it "raises TimeoutError when the response has timed_out: true" do
        results_double = double(total: 12)
        aggregations_double = double(dig: {})
        response_double = double(results: results_double, aggregations: aggregations_double, response: { "timed_out" => true })
        allow(Link).to receive(:search).and_return(response_double)

        expect { described_class.call(product:) }.to raise_error(PriceCheckerService::TimeoutError)
      end

      it "raises TimeoutError when the Ruby-level Timeout fires" do
        allow(Link).to receive(:search) do
          sleep 5
        end

        expect { described_class.call(product:) }.to raise_error(PriceCheckerService::TimeoutError)
      end
    end
  end
end
