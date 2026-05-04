# frozen_string_literal: true

require "spec_helper"

describe "Product::Searchable - Random sort" do
  it "wraps the existing query in function_score with a seeded random_score when sort is RANDOM" do
    options = Link.search_options(sort: ProductSortKey::RANDOM, random_seed: 42)

    expect(options[:query]).to have_key(:function_score)
    expect(options[:query][:function_score][:query]).to have_key(:bool)
    expect(options[:query][:function_score][:random_score][:seed]).to eq(42)
    expect(options[:query][:function_score][:random_score][:field]).to eq("_seq_no")
    expect(options[:query][:function_score][:boost_mode]).to eq("replace")
  end

  it "sorts by score descending when sort is RANDOM" do
    options = Link.search_options(sort: ProductSortKey::RANDOM, random_seed: 1)
    expect(options[:sort]).to eq([{ _score: { order: "desc" } }])
  end

  it "leaves the query untouched when sort is not RANDOM" do
    options = Link.search_options(sort: ProductSortKey::FEATURED)
    expect(options[:query]).not_to have_key(:function_score)
  end

  describe "applied against indexed products" do
    let(:seller) { create(:compliant_user) }

    before do
      20.times.map { |i| create(:product, :recommendable, user: seller, name: "thing #{i}", price_cents: 50) }
      Link.import(refresh: true, force: true)
    end

    it "returns the same ordering for repeated searches with the same seed" do
      first = Link.__elasticsearch__.search(Link.search_options(sort: ProductSortKey::RANDOM, random_seed: 12345, max_price: 1, size: 20)).records.map(&:id)
      second = Link.__elasticsearch__.search(Link.search_options(sort: ProductSortKey::RANDOM, random_seed: 12345, max_price: 1, size: 20)).records.map(&:id)
      expect(first).to eq(second)
    end

    it "returns a different ordering for different seeds" do
      first = Link.__elasticsearch__.search(Link.search_options(sort: ProductSortKey::RANDOM, random_seed: 12345, max_price: 1, size: 20)).records.map(&:id)
      second = Link.__elasticsearch__.search(Link.search_options(sort: ProductSortKey::RANDOM, random_seed: 99999, max_price: 1, size: 20)).records.map(&:id)
      expect(first).not_to eq(second)
    end
  end
end
