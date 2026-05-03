# frozen_string_literal: true

require "spec_helper"

describe ProductReadinessService do
  let(:product) do
    create(:product,
           name: "Master Lightroom in 14 days",
           description: "<p>A focused 30-day course.</p>",
           price_cents: 1999,
           display_product_reviews: true)
  end
  let(:service) { described_class.new(product: product) }

  before { Rails.cache.clear }

  describe "#call" do
    it "returns overall, severity, categories, and computed_at" do
      result = service.call
      expect(result).to include(:overall, :severity, :categories, :computed_at)
      expect(result[:categories].map { |c| c[:key] }).to eq(%w[name description cover pricing social_proof])
    end

    it "weights categories so the overall is the weighted average" do
      result = service.compute
      expected = result[:categories].sum { |c| c[:score] * c[:weight] }.fdiv(100).round
      expect(result[:overall]).to eq(expected)
    end

    it "caches the result on the second call" do
      first = service.call
      allow(service).to receive(:compute).and_call_original
      second = service.call
      expect(second).to eq(first)
      expect(service).not_to have_received(:compute)
    end

    it "uses a different cache key when scored fields change" do
      original_key = service.cache_key
      product.update!(name: "Master Lightroom in 14 days — for first-time wedding photographers")
      fresh_service = described_class.new(product: product.reload)
      expect(fresh_service.cache_key).not_to eq(original_key)
    end
  end

  describe "name scoring" do
    it "is missing when blank" do
      product.update_columns(name: "")
      cat = described_class.new(product: product.reload).compute[:categories].find { |c| c[:key] == "name" }
      expect(cat[:score]).to eq(0)
      expect(cat[:severity]).to eq("missing")
    end

    it "scores in the sweet spot length plus number plus action verb" do
      product.update!(name: "Master Lightroom in 14 days for photographers")
      cat = service.compute[:categories].find { |c| c[:key] == "name" }
      expect(cat[:score]).to eq(100)
      expect(cat[:details]).to include(match(/sweet spot/), "Contains a number", "Contains action verb")
    end

    it "penalises short names" do
      product.update!(name: "Short")
      cat = service.compute[:categories].find { |c| c[:key] == "name" }
      expect(cat[:score]).to be < 60
    end

    it "penalises overly long names" do
      product.update!(name: "A" * 90)
      cat = service.compute[:categories].find { |c| c[:key] == "name" }
      expect(cat[:score]).to be <= 60
    end
  end

  describe "description scoring" do
    it "is missing when blank" do
      product.update!(description: "")
      cat = service.compute[:categories].find { |c| c[:key] == "description" }
      expect(cat[:score]).to eq(0)
    end

    it "rewards structure (list, headings, audience phrasing, FAQ, numbers)" do
      body = "<h2>What's inside</h2>"
      body += "<p>For photographers who want to ship in 14 days.</p>"
      body += "<ul>#{"<li>item</li>" * 5}</ul>"
      body += "<p>FAQ:</p><p>" + ("word " * 250) + "</p>"
      product.update!(description: body)
      cat = service.compute[:categories].find { |c| c[:key] == "description" }
      expect(cat[:score]).to be >= 80
      expect(cat[:details]).to include("Has bullet list", "Has headings", "Has audience-of-one phrasing", "Includes FAQ section")
    end

    it "penalises sub-target word counts" do
      product.update!(description: "<p>Short copy.</p>")
      cat = service.compute[:categories].find { |c| c[:key] == "description" }
      expect(cat[:score]).to be < 30
    end
  end

  describe "cover scoring" do
    it "is missing when there is no cover" do
      cat = service.compute[:categories].find { |c| c[:key] == "cover" }
      expect(cat[:score]).to eq(0)
      expect(cat[:severity]).to eq("missing")
    end

    it "scores 60 with a single image cover" do
      create(:asset_preview, link: product)
      cat = described_class.new(product: product.reload).compute[:categories].find { |c| c[:key] == "cover" }
      expect(cat[:score]).to eq(60)
    end

    it "scores 100 with multiple covers and a video preview" do
      create(:asset_preview, link: product)
      create(:asset_preview_youtube, link: product)
      cat = described_class.new(product: product.reload).compute[:categories].find { |c| c[:key] == "cover" }
      expect(cat[:score]).to eq(100)
    end
  end

  describe "pricing scoring" do
    it "scores free products at 20" do
      allow(product).to receive(:price_cents).and_return(0)
      allow(product).to receive(:customizable_price?).and_return(false)
      cat = described_class.new(product: product).compute[:categories].find { |c| c[:key] == "pricing" }
      expect(cat[:score]).to eq(20)
    end

    it "rewards charm pricing ending in .99" do
      product.update!(price_cents: 1999)
      cat = service.compute[:categories].find { |c| c[:key] == "pricing" }
      expect(cat[:details]).to include("Charm pricing applied")
    end

    it "rewards charm pricing ending in 9 dollars" do
      product.update!(price_cents: 1900)
      cat = service.compute[:categories].find { |c| c[:key] == "pricing" }
      expect(cat[:details]).to include("Charm pricing applied")
    end

    it "does not call $20 charm priced" do
      product.update!(price_cents: 2000)
      cat = service.compute[:categories].find { |c| c[:key] == "pricing" }
      expect(cat[:details]).not_to include("Charm pricing applied")
    end
  end

  describe "social_proof scoring" do
    it "is missing when there are no reviews" do
      cat = service.compute[:categories].find { |c| c[:key] == "social_proof" }
      expect(cat[:score]).to eq(0)
    end

    it "rewards higher review counts and ratings" do
      product.create_product_review_stat!(reviews_count: 100, average_rating: 4.7)
      cat = described_class.new(product: product.reload).compute[:categories].find { |c| c[:key] == "social_proof" }
      expect(cat[:score]).to be >= 90
    end

    it "discounts the score by 30% when reviews are hidden" do
      product.create_product_review_stat!(reviews_count: 100, average_rating: 4.0)
      product.update!(display_product_reviews: false)
      cat = described_class.new(product: product.reload).compute[:categories].find { |c| c[:key] == "social_proof" }
      expect(cat[:details]).to include("Reviews hidden on product page (-30%)")
      expect(cat[:score]).to be < 70
    end
  end

  describe "severity bands" do
    it "labels 80+ as good, 60-79 as ok, 40-59 as weak, otherwise missing" do
      result = service.compute
      expect(result[:severity]).to eq(
        case result[:overall]
        when 80..100 then "good"
        when 60..79 then "ok"
        when 40..59 then "weak"
        else "missing"
        end
      )
    end
  end
end
