# frozen_string_literal: true

require "spec_helper"

describe "Product::Searchable - Taxonomy attribute filters" do
  let(:taxonomy) { create(:taxonomy) }
  let(:creator) { create(:user) }

  before do
    TaxonomyAttribute.create!(taxonomy:, name: "format", label: "Format", value_type: "enum", values: ["OTF", "TTF"], position: 0)
    TaxonomyAttribute.create!(taxonomy:, name: "license", label: "License", value_type: "enum", values: ["Personal", "Commercial"], position: 1)

    @otf_commercial = create(:product, taxonomy:, user: creator)
    @otf_commercial.save_taxonomy_attribute_values("format" => "OTF", "license" => "Commercial")
    @otf_personal = create(:product, taxonomy:, user: creator)
    @otf_personal.save_taxonomy_attribute_values("format" => "OTF", "license" => "Personal")
    @ttf_commercial = create(:product, taxonomy:, user: creator)
    @ttf_commercial.save_taxonomy_attribute_values("format" => "TTF", "license" => "Commercial")

    Link.import(refresh: true, force: true)
  end

  it "requires every selected attribute dimension to match" do
    search_options = Link.search_options(user_id: creator.id, taxonomy_id: taxonomy.id, taxonomy_attribute_filters: ["format:otf", "license:commercial"])
    records = Link.__elasticsearch__.search(search_options).records

    expect(records).to include(@otf_commercial)
    expect(records).not_to include(@otf_personal, @ttf_commercial)
  end

  it "matches any selected value within one attribute" do
    search_options = Link.search_options(user_id: creator.id, taxonomy_id: taxonomy.id, taxonomy_attribute_filters: ["format:otf", "format:ttf"])
    records = Link.__elasticsearch__.search(search_options).records

    expect(records).to include(@otf_commercial, @otf_personal, @ttf_commercial)
  end

  it "counts sibling facet values without the current taxonomy attribute filters" do
    response = Link.search(Link.taxonomy_attribute_options(user_id: creator.id, taxonomy_id: taxonomy.id, taxonomy_attribute_filters: ["format:otf"]))
    buckets = response.aggregations["taxonomy_attribute_filters"]["buckets"].index_by { _1["key"] }

    expect(buckets["format:ttf"]["doc_count"]).to eq(1)
    expect(buckets["license:commercial"]["doc_count"]).to eq(2)
  end

  context "when two taxonomies independently define the same attribute name and value" do
    let(:other_taxonomy) { create(:taxonomy) }

    before do
      TaxonomyAttribute.create!(taxonomy: other_taxonomy, name: "format", label: "Format", value_type: "enum", values: ["OTF"], position: 0)

      @other_taxonomy_otf = create(:product, taxonomy: other_taxonomy, user: creator)
      @other_taxonomy_otf.save_taxonomy_attribute_values("format" => "OTF")

      Link.import(refresh: true, force: true)
    end

    it "does not match a product filtered under a different taxonomy" do
      search_options = Link.search_options(user_id: creator.id, taxonomy_id: taxonomy.id, taxonomy_attribute_filters: ["format:otf"])
      records = Link.__elasticsearch__.search(search_options).records

      expect(records).to include(@otf_commercial, @otf_personal)
      expect(records).not_to include(@other_taxonomy_otf)
    end

    it "matches across both taxonomies when no taxonomy_id is given, which is why the filter requires one" do
      search_options = Link.search_options(user_id: creator.id, taxonomy_attribute_filters: ["format:otf"])
      records = Link.__elasticsearch__.search(search_options).records

      expect(records).to include(@otf_commercial, @otf_personal, @other_taxonomy_otf)
    end
  end
end
