# frozen_string_literal: true

require "spec_helper"

describe "Product::Searchable - Name fields search scenarios" do
  before do
    @product = create(:product_with_files)
  end

  describe "on name fields for all products", :elasticsearch_wait_for_refresh do
    before do
      Link.__elasticsearch__.create_index!(force: true)
      @product_1 = create(:product, name: "Sample propaganda for antienvironmentalists")
      allow(@product_1).to receive(:recommendable?).and_return(true)
      create(:product_review, purchase: create(:purchase, link: @product_1))
      @product_1.__elasticsearch__.index_document
    end

    shared_examples_for "includes product" do |query|
      it "when query is '#{query}'" do
        args = Link.partial_search_options(query:)
        records = Link.__elasticsearch__.search(args).records.to_a
        expect(records).to include(@product_1)
      end
    end

    shared_examples_for "not includes product" do |query|
      it "when query is '#{query}'" do
        args = Link.partial_search_options(query:)
        records = Link.__elasticsearch__.search(args).records.to_a
        expect(records).to_not include(@product_1)
      end
    end

    it_behaves_like "includes product", "propaganda"
    it_behaves_like "includes product", "sample propa"
    it_behaves_like "includes product", "Sample propaganda for an"
    it_behaves_like "includes product", "propaganda sample"
    it_behaves_like "includes product", "Sa"
    it_behaves_like "includes product", "for"
    it_behaves_like "not includes product", "p"
    it_behaves_like "not includes product", "b"
    it_behaves_like "not includes product", "amp"
    it_behaves_like "not includes product", "antienvironmentalistic"
    it_behaves_like "not includes product", "anticapitalist"
    it_behaves_like "not includes product", "Sample propaganda for envi"

    it "supports ES query syntax" do
      product_2 = create(:product, name: "Sample photography book")
      allow(product_2).to receive(:recommendable?).and_return(true)
      create(:product_review, purchase: create(:purchase, link: product_2))
      product_2.__elasticsearch__.index_document

      args = Link.partial_search_options(query: "sample -propaganda")
      records = Link.__elasticsearch__.search(args).records.to_a
      expect(records).to_not include(@product_1)
      expect(records).to include(product_2)
    end

    it "sorts products by sales_volume and created_at", :sidekiq_inline do
      products = create_list(:product, 3, name: "Sample", price_cents: 200)
      products << create(:product, name: "Sample", price_cents: 100, created_at: Time.current + 5.seconds)
      products.each_with_index do |product, i|
        allow(product).to receive(:recommendable?).and_return(true)
        i.times { create(:purchase, link: product) }
        create(:product_review, purchase: create(:purchase, link: product))
        product.__elasticsearch__.index_document
      end
      args = Link.partial_search_options(query: "sampl")
      records = Link.__elasticsearch__.search(args).records.to_a
      expect(records).to start_with(*products.values_at(2, 3, 1, 0))
    end

    context "filtering" do
      before do
        @product_not_recommendable = create(:product, name: "sample")
        @product_recommendable_sfw = create(:product, :recommendable, name: "sample")
        @product_recommendable_nsfw = create(:product, :recommendable, name: "sample", is_adult: true)
      end

      it "excludes non-recommendable and recommendable-adult products" do
        args = Link.partial_search_options(query: "sampl")
        records = Link.search(args).records.to_a
        expect(records).not_to include(@product_not_recommendable, @product_recommendable_nsfw)
        expect(records).to include(@product_recommendable_sfw)
      end

      it "excludes non-recommendable products, but keeps adult recommendable ones when include_rated_as_adult is true" do
        args = Link.partial_search_options(query: "sampl", include_rated_as_adult: true)
        records = Link.search(args).records.to_a
        expect(records).not_to include(@product_not_recommendable)
        expect(records).to include(@product_recommendable_sfw, @product_recommendable_nsfw)
      end
    end
  end
end
