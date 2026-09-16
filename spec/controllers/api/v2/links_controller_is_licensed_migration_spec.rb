# frozen_string_literal: true

require "spec_helper"

# `is_licensed` is derived from the embedded License key block, but the update
# recomputed it from the product's loaded rich-content associations. Switching a
# product between shared and per-version content writes pages through those same
# loaded collections, so the recompute could read the pre-move rows and clear the
# flag while the block was still there — after which no purchase got a license key.
describe Api::V2::LinksController do
  before do
    @user = create(:user)
    @app = create(:oauth_application, owner: create(:user))
    @product = create(:product, user: @user, description: "des1", price_cents: 500)
    @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
    @params = { id: @product.external_id, access_token: @token.token, format: :json }
    @category = create(:variant_category, link: @product, title: "Version")
    @variant = create(:variant, variant_category: @category, name: "Pro")
  end

  def license_page
    [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "License" }] },
     { "type" => "licenseKey" }]
  end

  def plain_page(text)
    [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => text }] }]
  end

  it "keeps is_licensed when the switch to per-variant content moves a licensed page down" do
    create(:rich_content, entity: @product, title: "License", description: license_page)
    @product.update!(has_same_rich_content_for_all_variants: true, is_licensed: true)

    put :update, params: @params.merge(has_same_rich_content_for_all_variants: false)

    expect(response.parsed_body["success"]).to be(true)
    @product.reload
    expect(@product.has_embedded_license_key?).to eq(true)
    expect(@product.is_licensed).to eq(true)
  end

  it "keeps is_licensed when the switch to shared content moves a licensed page up" do
    create(:rich_content, entity: @variant, title: "License", description: license_page, position: 0)
    @product.update!(has_same_rich_content_for_all_variants: false, is_licensed: true)

    put :update, params: @params.merge(has_same_rich_content_for_all_variants: true)

    expect(response.parsed_body["success"]).to be(true)
    @product.reload
    expect(@product.has_embedded_license_key?).to eq(true)
    expect(@product.is_licensed).to eq(true)
  end

  it "clears is_licensed and is_multiseat_license when the moved page has no license key" do
    create(:rich_content, entity: @product, title: "Plain", description: plain_page("No license"))
    @product.update!(has_same_rich_content_for_all_variants: true, is_licensed: true, is_multiseat_license: true)

    put :update, params: @params.merge(has_same_rich_content_for_all_variants: false)

    expect(response.parsed_body["success"]).to be(true)
    @product.reload
    expect(@product.has_embedded_license_key?).to eq(false)
    expect(@product.is_licensed).to eq(false)
    expect(@product.is_multiseat_license).to eq(false)
  end
end
