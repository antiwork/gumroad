# frozen_string_literal: true

require "spec_helper"

# Regression coverage for gumroad-private#2023: client page ids are unique per
# scope, not globally, so `ensure_rich_content_ids_are_unambiguous!` must tally
# them per scope — the same raw id in two different variants is legitimate
# (shared/per-tier toggles produce it), while a same-scope collision stays rejected.
describe LinksController, type: :controller do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }

  before { sign_in seller }

  def paragraph(text)
    [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => text }] }]
  end

  def editor_save_params(variants_params, rich_content_params: [])
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
      rich_content: rich_content_params,
      variants: variants_params,
      confirmed_removed_variant_ids: [],
      confirmed_removed_rich_content_ids: [],
      preserved_rich_content_ids: [],
      rich_content_provenance_version: 2,
    }
  end

  it "accepts the same raw client id reused across two different variant scopes" do
    category = create(:variant_category, link: product, title: "Tier")
    tier_a = create(:variant, variant_category: category, name: "Tier A")
    tier_b = create(:variant, variant_category: category, name: "Tier B")

    # Same raw client id under two different variants — must be accepted.
    params = editor_save_params(
      [
        {
          id: tier_a.external_id,
          name: tier_a.name,
          price_difference_cents: 0,
          rich_content: [
            { id: "shared-client-id", title: "A", description: { type: "doc", content: paragraph("New A") } }
          ],
        },
        {
          id: tier_b.external_id,
          name: tier_b.name,
          price_difference_cents: 0,
          rich_content: [
            { id: "shared-client-id", title: "B", description: { type: "doc", content: paragraph("New B") } }
          ],
        }
      ]
    )

    legacy_params = params.deep_dup
    legacy_params[:rich_content_provenance_version] = 1
    post :update, params: legacy_params, as: :json
    expect(response).to have_http_status(:conflict).or have_http_status(:unprocessable_entity)

    post :update, params: params, as: :json
    expect(response).to be_successful
    tier_a_page = tier_a.reload.alive_rich_contents.sole
    tier_b_page = tier_b.reload.alive_rich_contents.sole
    mappings = response.parsed_body.fetch("rich_content_id_mappings_by_scope")
    expect(mappings.dig(tier_a.external_id, "shared-client-id")).to eq(tier_a_page.external_id)
    expect(mappings.dig(tier_b.external_id, "shared-client-id")).to eq(tier_b_page.external_id)
    expect(tier_a_page.external_id).not_to eq(tier_b_page.external_id)
  end

  it "still rejects a genuine same-scope duplicate id" do
    category = create(:variant_category, link: product, title: "Tier")
    tier_a = create(:variant, variant_category: category, name: "Tier A")
    page_1 = create(:rich_content, entity: tier_a, title: "One", description: paragraph("Original 1"))
    page_2 = create(:rich_content, entity: tier_a, title: "Two", description: paragraph("Original 2"))

    params = editor_save_params(
      [
        {
          id: tier_a.external_id,
          name: tier_a.name,
          price_difference_cents: 0,
          rich_content: [
            { id: page_1.external_id, title: "One", description: { type: "doc", content: paragraph("Edited 1") } },
            { id: page_2.external_id, title: "Two", description: { type: "doc", content: paragraph("Edited 2") } }
          ],
        }
      ]
    )
    # Same raw id reused for two pages WITHIN the same variant — this is the
    # ambiguous case the guard exists to catch and must still be rejected.
    params[:variants][0][:rich_content][0][:id] = "dup-id"
    params[:variants][0][:rich_content][1][:id] = "dup-id"

    post :update, params: params, as: :json

    expect(response).to have_http_status(:conflict).or have_http_status(:unprocessable_entity)
  end
end
