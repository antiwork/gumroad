# frozen_string_literal: true

require "spec_helper"

# Regression coverage for a Greptile P1 on #6858: save_taxonomy_attribute_values only
# ran when the request included taxonomy_attribute_values, so a category-only save
# (or an older client / API request that never sends the attributes field) changed
# taxonomy_id while leaving the previous taxonomy's values stuck in json_data.
describe LinksController, type: :controller do
  let(:seller) { create(:user) }
  let(:fonts) { Taxonomy.find_or_create_by!(slug: "fonts", parent: Taxonomy.find_or_create_by!(slug: "design")) }
  let(:software) { Taxonomy.find_or_create_by!(slug: "software-development") }

  before do
    TaxonomyAttribute.where(taxonomy: fonts).delete_all
    TaxonomyAttribute.create!(taxonomy: fonts, name: "format", label: "Format", value_type: "enum", values: %w[OTF TTF WOFF2], position: 0)
    sign_in seller
  end

  def editor_save_params(product, overrides = {})
    {
      id: product.unique_permalink,
      name: product.name,
      description: "A description",
      price_currency_type: "usd",
      price_cents: product.price_cents,
      customizable_price: false,
      covers: [],
      files: [],
      has_same_rich_content_for_all_variants: false,
      rich_content: [],
      variants: [],
      confirmed_removed_variant_ids: [],
      confirmed_removed_rich_content_ids: [],
      preserved_rich_content_ids: [],
      rich_content_provenance_version: 1,
    }.merge(overrides)
  end

  it "clears the old taxonomy's attribute values on a category-only save that omits taxonomy_attribute_values" do
    product = create(:product, user: seller, taxonomy: fonts)
    product.save_taxonomy_attribute_values("format" => "OTF")
    expect(product.reload.seller_taxonomy_attribute_values).to eq("format" => "OTF")

    params = editor_save_params(product, taxonomy_id: software.id)
    post :update, params: params, as: :json

    expect(response).to be_successful
    expect(product.reload.seller_taxonomy_attribute_values).to eq({})
  end

  it "still saves submitted values when the request does include taxonomy_attribute_values" do
    product = create(:product, user: seller, taxonomy: fonts)

    params = editor_save_params(product, taxonomy_attribute_values: { format: "TTF" })
    post :update, params: params, as: :json

    expect(response).to be_successful
    expect(product.reload.seller_taxonomy_attribute_values).to eq("format" => "TTF")
  end

  it "does not touch attribute values on a save with no taxonomy change" do
    product = create(:product, user: seller, taxonomy: fonts)
    product.save_taxonomy_attribute_values("format" => "OTF")

    params = editor_save_params(product)
    post :update, params: params, as: :json

    expect(response).to be_successful
    expect(product.reload.seller_taxonomy_attribute_values).to eq("format" => "OTF")
  end
end
