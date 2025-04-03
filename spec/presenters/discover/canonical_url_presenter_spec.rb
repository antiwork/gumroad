# frozen_string_literal: true

require "spec_helper"

describe Discover::CanonicalUrlPresenter do
  let(:discover_domain_with_protocol) { UrlService.discover_domain_with_protocol }
  describe "#canonical_url" do
    it "returns the root url when no valid search parameters are present" do
      params = ActionController::Parameters.new({})
      expect(described_class.canonical_url(params)).to eq("#{discover_domain_with_protocol}/")

      params = ActionController::Parameters.new({ sort: "hot_and_new" })
      expect(described_class.canonical_url(params)).to eq("#{discover_domain_with_protocol}/")

      params = ActionController::Parameters.new({ max_price: 0 })
      expect(described_class.canonical_url(params)).to eq("#{discover_domain_with_protocol}/")
    end

    it "returns the url with parameters" do
      params = ActionController::Parameters.new({ query: "product" })
      expect(described_class.canonical_url(params)).to eq("#{discover_domain_with_protocol}/?query=product")

      params = ActionController::Parameters.new({ taxonomy: "3d/3d-modeling" })
      expect(described_class.canonical_url(params)).to eq("#{discover_domain_with_protocol}/3d/3d-modeling")

      params = ActionController::Parameters.new({ taxonomy: "3d/3d-modeling", query: "product" })
      expect(described_class.canonical_url(params)).to eq("#{discover_domain_with_protocol}/3d/3d-modeling?query=product")

      params = ActionController::Parameters.new({ tags: ["3d model"] })
      expect(described_class.canonical_url(params)).to eq("#{discover_domain_with_protocol}/?tags=3d+model")
    end

    it "returns the url with sorted parameters and values" do
      params = ActionController::Parameters.new({ rating: 1, query: "product", sort: "featured" })
      expect(described_class.canonical_url(params)).to eq("#{discover_domain_with_protocol}/?query=product&rating=1&sort=featured")

      params = ActionController::Parameters.new({ max_price: 1, tags: ["tagb", "taga"], sort: "hot_and_new" })
      expect(described_class.canonical_url(params)).to eq("#{discover_domain_with_protocol}/?max_price=1&sort=hot_and_new&tags=taga%2Ctagb")

      params = ActionController::Parameters.new({ max_price: 1, tags: ["taga", "tagb"], sort: "hot_and_new" })
      expect(described_class.canonical_url(params)).to eq("#{discover_domain_with_protocol}/?max_price=1&sort=hot_and_new&tags=taga%2Ctagb")
    end

    it "ignores empty parameters" do
      params = ActionController::Parameters.new({ query: "product", max_price: 0, tags: [], sort: "" })
      expect(described_class.canonical_url(params)).to eq("#{discover_domain_with_protocol}/?max_price=0&query=product")
    end

    it "ignores invalid parameters" do
      params = ActionController::Parameters.new({ query: "product", invalid: "invalid", unknown: "unknown" })
      expect(described_class.canonical_url(params)).to eq("#{discover_domain_with_protocol}/?query=product")
    end

    it "correctly formats array parameters" do
      params = ActionController::Parameters.new({ tags: ["tag1", "tag2"], filetypes: ["mp3", "zip"] })
      expect(described_class.canonical_url(params)).to eq("#{discover_domain_with_protocol}/?filetypes=mp3%2Czip&tags=tag1%2Ctag2")
    end
  end
end
