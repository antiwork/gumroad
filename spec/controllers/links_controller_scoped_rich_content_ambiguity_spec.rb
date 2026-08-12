# frozen_string_literal: true

require "spec_helper"

# Regression coverage for gumroad-private#2023.
#
# `ensure_rich_content_ids_are_unambiguous!` used to tally submitted page ids
# GLOBALLY across the whole save payload. Client-generated page ids are only
# unique WITHIN a scope (product-level, or a given variant) — the same raw id
# legitimately shows up once per variant when pages move between shared/
# per-tier scopes in one save (e.g. toggling "use same content for all
# versions"). The old global tally rejected that save outright with
# "references the same content page more than once", before the request ever
# reached the reconciliation logic PR#7178 fixed client-side — so the
# client-side fix alone could never be exercised end-to-end for its own target
# scenario. This spec pins that the same raw id in two DIFFERENT variant
# scopes is accepted, while a genuine same-scope collision is still rejected.
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

    # Same raw client id ("shared-client-id") submitted as a NEW page under
    # two different variants — plausible after a shared/per-tier toggle
    # round-trip generates both from the same source pass. This must be
    # accepted: the ids are scoped per variant, not globally unique.
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

  it "rejects an existing page id submitted under two different variant scopes" do
    category = create(:variant_category, link: product, title: "Tier")
    tier_a = create(:variant, variant_category: category, name: "Tier A")
    tier_b = create(:variant, variant_category: category, name: "Tier B")
    page = create(:rich_content, entity: tier_a, title: "One", description: paragraph("Original"))

    params = editor_save_params(
      [
        {
          id: tier_a.external_id,
          name: tier_a.name,
          price_difference_cents: 0,
          rich_content: [
            { id: page.external_id, title: "One", description: { type: "doc", content: paragraph("Kept") } }
          ],
        },
        {
          id: tier_b.external_id,
          name: tier_b.name,
          price_difference_cents: 0,
          rich_content: [
            { id: page.external_id, title: "One", description: { type: "doc", content: paragraph("Also here") } }
          ],
        }
      ]
    )

    post :update, params: params, as: :json

    expect(response).to have_http_status(:conflict)
    expect(page.reload.entity).to eq(tier_a)
  end

  # gumroad-private#2023 stayed open through two fix attempts because the 409s
  # left no record of which check fired or on what payload. These pin the
  # classification line each refusal now writes.
  describe "conflict logging" do
    before { allow(Rails.logger).to receive(:info).and_call_original }

    it "logs the per-scope duplicate check with the offending id" do
      category = create(:variant_category, link: product, title: "Tier")
      tier_a = create(:variant, variant_category: category, name: "Tier A")

      params = editor_save_params(
        [
          {
            id: tier_a.external_id,
            name: tier_a.name,
            price_difference_cents: 0,
            rich_content: [
              { id: "dup-id", title: "One", description: { type: "doc", content: paragraph("1") } },
              { id: "dup-id", title: "Two", description: { type: "doc", content: paragraph("2") } }
            ],
          }
        ]
      )

      post :update, params: params, as: :json

      expect(response).to have_http_status(:conflict)
      expect(Rails.logger).to have_received(:info).with(
        a_string_including(
          "[product_editor_save_conflict]",
          "error_code=ambiguous_rich_content_id_conflict",
          "product_id=#{product.id}",
          "provenance_version=2",
          'check="per_scope"',
          "dup-id"
        )
      )
    end

    it "logs the global check for a payload without scoped-mapping support" do
      category = create(:variant_category, link: product, title: "Tier")
      tier_a = create(:variant, variant_category: category, name: "Tier A")
      tier_b = create(:variant, variant_category: category, name: "Tier B")

      params = editor_save_params(
        [
          {
            id: tier_a.external_id,
            name: tier_a.name,
            price_difference_cents: 0,
            rich_content: [
              { id: "shared-client-id", title: "A", description: { type: "doc", content: paragraph("A") } }
            ],
          },
          {
            id: tier_b.external_id,
            name: tier_b.name,
            price_difference_cents: 0,
            rich_content: [
              { id: "shared-client-id", title: "B", description: { type: "doc", content: paragraph("B") } }
            ],
          }
        ]
      )
      params[:rich_content_provenance_version] = 1

      post :update, params: params, as: :json

      expect(response).to have_http_status(:conflict)
      expect(Rails.logger).to have_received(:info).with(
        a_string_including(
          "error_code=ambiguous_rich_content_id_conflict",
          "provenance_version=1",
          'check="global"',
          "shared-client-id"
        )
      )
    end

    it "logs the existing-id check with the id and both scopes" do
      category = create(:variant_category, link: product, title: "Tier")
      tier_a = create(:variant, variant_category: category, name: "Tier A")
      tier_b = create(:variant, variant_category: category, name: "Tier B")
      page = create(:rich_content, entity: tier_a, title: "One", description: paragraph("Original"))

      params = editor_save_params(
        [
          {
            id: tier_a.external_id,
            name: tier_a.name,
            price_difference_cents: 0,
            rich_content: [
              { id: page.external_id, title: "One", description: { type: "doc", content: paragraph("Kept") } }
            ],
          },
          {
            id: tier_b.external_id,
            name: tier_b.name,
            price_difference_cents: 0,
            rich_content: [
              { id: page.external_id, title: "One", description: { type: "doc", content: paragraph("Also here") } }
            ],
          }
        ]
      )

      post :update, params: params, as: :json

      expect(response).to have_http_status(:conflict)
      expect(Rails.logger).to have_received(:info).with(
        a_string_including(
          "error_code=ambiguous_rich_content_id_conflict",
          'check="existing_id_multiple_scopes"',
          page.external_id
        )
      )
    end
  end
end
