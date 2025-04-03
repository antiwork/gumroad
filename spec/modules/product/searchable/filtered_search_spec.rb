# frozen_string_literal: true

require "spec_helper"

describe "Product::Searchable - Filtered search scenarios" do
  describe "filters adult products for recommendable products" do
    before do
      @creator = create(:recommendable_user, username: "a" + SecureRandom.random_number(1e15).round.to_s, name: "Gumbot")
      @adult_creator = create(:recommendable_user, name: "Gumbot", bio: "nsfw stuff")
    end

    it "does not filter products when user_id is given" do
      product_1 = create(:product, :recommendable, is_adult: true, user: @creator)
      product_2 = create(:product, :recommendable, is_adult: false, user: @creator)

      Link.import(refresh: true, force: true)
      # Search by user_id to avoid check on "recommendable" field which
      # filters products with is_adult by default
      search_options = Link.search_options(user_id: @creator.id)
      records = Link.__elasticsearch__.search(search_options).records
      expect(records).to include(product_1, product_2)
    end
  end

  it "supports ES query syntax" do
    creator = create(:compliant_user, username: "a" + SecureRandom.random_number(1e15).round.to_s)

    product_1 = create(:product_with_files, :recommendable, name: "photo presets", user: creator)
    product_2 = create(:product_with_files, :recommendable, name: "photo book", user: creator)
    Link.import(refresh: true, force: true)

    search_options = Link.search_options(query: "photo -presets")
    records = Link.__elasticsearch__.search(search_options).records
    expect(records).not_to include product_1
    expect(records).to include product_2
  end
end
