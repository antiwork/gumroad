# frozen_string_literal: true

require "spec_helper"

# A save that moves pages between the product and its versions leaves the loaded rich-content
# associations pre-write, so the recompute reads the stored rows (Link#recompute_is_licensed!).
describe LinksController, type: :controller do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:variant_category) { create(:variant_category, link: product, title: "Version") }
  let!(:variant) { create(:variant, variant_category: variant_category, name: "Pro") }

  before { sign_in seller }

  def license_page
    [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "License" }] },
     { "type" => "licenseKey" }]
  end

  def plain_page(text)
    [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => text }] }]
  end

  def editor_save_params(overrides)
    {
      id: product.unique_permalink,
      name: product.name,
      description: "A description",
      price_currency_type: "usd",
      price_cents: product.price_cents,
      customizable_price: false,
      covers: [],
      files: [],
      variants: [],
      rich_content: [],
      confirmed_removed_variant_ids: [],
      confirmed_removed_rich_content_ids: [],
      preserved_rich_content_ids: [],
      rich_content_provenance_version: 1,
    }.merge(overrides)
  end

  def variant_params(rich_content)
    [
      {
        id: variant.external_id,
        name: variant.name,
        price_difference_cents: 0,
        rich_content: rich_content,
      }
    ]
  end

  it "keeps is_licensed when the save moves a licensed page from the product level into a version" do
    create(:rich_content, entity: product, title: "License", description: license_page)
    product.update!(has_same_rich_content_for_all_variants: true, is_licensed: true)

    post :update, params: editor_save_params(
      has_same_rich_content_for_all_variants: false,
      rich_content: [],
      variants: variant_params(
        [{ id: "page-1", title: "License", description: { type: "doc", content: license_page } }]
      )
    ), as: :json

    expect(response).to be_successful
    product.reload
    expect(product.has_embedded_license_key?).to eq(true)
    expect(product.is_licensed).to eq(true)
  end

  it "clears is_licensed and is_multiseat_license when the last license key block is removed" do
    page = create(:rich_content, entity: variant, title: "License", description: license_page, position: 0)
    product.update!(has_same_rich_content_for_all_variants: false, is_licensed: true, is_multiseat_license: true)

    post :update, params: editor_save_params(
      has_same_rich_content_for_all_variants: false,
      variants: variant_params(
        [{ id: page.external_id, title: "No license", description: { type: "doc", content: plain_page("No license here") } }]
      )
    ), as: :json

    expect(response).to be_successful
    product.reload
    expect(product.has_embedded_license_key?).to eq(false)
    expect(product.is_licensed).to eq(false)
    expect(product.is_multiseat_license).to eq(false)
  end
end
