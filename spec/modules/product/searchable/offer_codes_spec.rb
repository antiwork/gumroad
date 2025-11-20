# frozen_string_literal: true

require "spec_helper"

describe "Product::Searchable - Offer codes filtering" do
  describe "filtering by offer_codes", :elasticsearch_wait_for_refresh do
    before do
      Link.__elasticsearch__.create_index!(force: true)

      Feature.activate(:offer_codes_search)

      @creator = create(:recommendable_user)
      @offer_code = create(:offer_code, user: @creator, code: "BLACKFRIDAY2025")

      @product_with_offer = create(:product, :recommendable, user: @creator, name: "Product with Black Friday")
      @product_with_offer.offer_codes << @offer_code

      @product_without_offer = create(:product, :recommendable, user: @creator, name: "Product without offer")

      @other_offer_code = create(:offer_code, user: @creator, code: "SUMMER2025")
      @product_with_other_offer = create(:product, :recommendable, user: @creator, name: "Product with other offer")
      @product_with_other_offer.offer_codes << @other_offer_code

      index_model_records(Link)
    end

    after do
      Feature.deactivate(:offer_codes_search)
    end

    it "returns only products with BLACKFRIDAY2025 offer code" do
      args = Link.search_options(offer_codes: ["BLACKFRIDAY2025"])
      records = Link.__elasticsearch__.search(args).records.to_a

      expect(records).to include(@product_with_offer)
      expect(records).not_to include(@product_without_offer)
      expect(records).not_to include(@product_with_other_offer)
    end

    it "returns all products when offer_codes param is not provided" do
      args = Link.search_options({})
      records = Link.__elasticsearch__.search(args).records.to_a

      expect(records).to include(@product_with_offer)
      expect(records).to include(@product_without_offer)
      expect(records).to include(@product_with_other_offer)
    end

    it "returns all products when searching for a non-BLACKFRIDAY2025 code" do
      # When feature flag is active, non-allowed codes are filtered out by SearchProducts concern
      # The controller filters the codes before passing to search_options, resulting in an empty array
      # An empty array is not present, so no filtering is applied and all products are returned
      args = Link.search_options(offer_codes: [])
      records = Link.__elasticsearch__.search(args).records.to_a

      expect(records).to include(@product_with_offer)
      expect(records).to include(@product_without_offer)
      expect(records).to include(@product_with_other_offer)
    end

    it "returns products when offer code is deleted and reindexed" do
      @product_with_offer.offer_codes.delete(@offer_code)
      @product_with_offer.enqueue_index_update_for(["offer_codes"])
      index_model_records(Link)

      args = Link.search_options(offer_codes: ["BLACKFRIDAY2025"])
      records = Link.__elasticsearch__.search(args).records.to_a

      expect(records).not_to include(@product_with_offer)
    end
  end

  describe "offer codes indexing" do
    before do
      @creator = create(:recommendable_user)
      @product = create(:product, user: @creator)
      @offer_code_1 = create(:offer_code, user: @creator, code: "CODE1")
      @offer_code_2 = create(:offer_code, user: @creator, code: "CODE2")
      @deleted_offer = create(:offer_code, user: @creator, code: "DELETED", deleted_at: Time.current)
    end

    it "includes all alive offer codes in search property" do
      @product.offer_codes << @offer_code_1
      @product.offer_codes << @offer_code_2
      @product.offer_codes << @deleted_offer

      expect(@product.send(:build_search_property, "offer_codes")).to contain_exactly("CODE1", "CODE2")
    end

    it "returns empty array when product has no offer codes" do
      expect(@product.send(:build_search_property, "offer_codes")).to eq([])
    end
  end
end
