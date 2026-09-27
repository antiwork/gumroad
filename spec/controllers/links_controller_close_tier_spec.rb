# frozen_string_literal: true

require "spec_helper"

describe LinksController, type: :controller do
  let(:seller) { create(:user) }
  let!(:product) { create(:membership_product, user: seller) }
  let(:tier) { product.tiers.first }

  before do
    Feature.activate_user(:close_membership_tier_to_new_buyers, seller)
    sign_in seller
  end

  def editor_save_params(tier_overrides = {})
    {
      id: product.unique_permalink,
      name: product.name,
      description: "A description",
      price_currency_type: "usd",
      covers: [],
      files: [],
      has_same_rich_content_for_all_variants: false,
      rich_content: [],
      variants: [{ id: tier.external_id, name: tier.name, description: "", max_purchase_count: nil, rich_content: [] }.merge(tier_overrides)],
      confirmed_removed_variant_ids: [],
      confirmed_removed_rich_content_ids: [],
      preserved_rich_content_ids: [],
      rich_content_provenance_version: 2,
    }
  end

  it "round-trips the close setting through the editor save" do
    post :update, params: editor_save_params(closed_to_new_purchases: true), as: :json
    expect(response).to be_successful
    expect(tier.reload.closed_to_new_purchases?).to be(true)

    post :update, params: editor_save_params, as: :json
    expect(response).to be_successful
    expect(tier.reload.closed_to_new_purchases?).to be(true)

    post :update, params: editor_save_params(closed_to_new_purchases: false), as: :json
    expect(response).to be_successful
    expect(tier.reload.closed_to_new_purchases?).to be(false)
  end

  it "refuses a stale tab's save that would reopen a tier closed after it loaded" do
    Feature.activate(Product::StaleContentWriteGuard::BLOCK_FEATURE_NAME)
    stale_snapshot = Product::StaleContentWriteGuard.snapshot_at(tier).as_json
    travel 1.minute
    tier.update!(closed_to_new_purchases: true)

    post :update, params: editor_save_params(closed_to_new_purchases: false, updated_at: stale_snapshot), as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["stale_records"].map { _1["id"] }).to eq([tier.external_id])
    expect(tier.reload.closed_to_new_purchases?).to be(true)
  end

  it "accepts a stale tab's save that sends a null close setting, since that leaves the tier as it is" do
    Feature.activate(Product::StaleContentWriteGuard::BLOCK_FEATURE_NAME)
    stale_snapshot = Product::StaleContentWriteGuard.snapshot_at(tier).as_json
    travel 1.minute
    tier.update!(closed_to_new_purchases: true)

    post :update, params: editor_save_params(closed_to_new_purchases: nil, updated_at: stale_snapshot), as: :json

    expect(response).to be_successful
    expect(tier.reload.closed_to_new_purchases?).to be(true)
  end

  it "accepts a stale tab's close value once the feature is off for the seller, and leaves the tier closed" do
    Feature.activate(Product::StaleContentWriteGuard::BLOCK_FEATURE_NAME)
    stale_snapshot = Product::StaleContentWriteGuard.snapshot_at(tier).as_json
    travel 1.minute
    tier.update!(closed_to_new_purchases: true)
    Feature.deactivate_user(:close_membership_tier_to_new_buyers, seller)

    post :update, params: editor_save_params(closed_to_new_purchases: false, updated_at: stale_snapshot), as: :json

    expect(response).to be_successful
    expect(tier.reload.closed_to_new_purchases?).to be(true)
  end

  it "accepts a stale tab's save whose close value casts to the stored one" do
    Feature.activate(Product::StaleContentWriteGuard::BLOCK_FEATURE_NAME)
    stale_snapshot = Product::StaleContentWriteGuard.snapshot_at(tier).as_json
    travel 1.minute
    tier.update!(closed_to_new_purchases: true)

    ["1", ""].each do |closed|
      post :update, params: editor_save_params(closed_to_new_purchases: closed, updated_at: stale_snapshot), as: :json

      expect(response).to be_successful
      expect(tier.reload.closed_to_new_purchases?).to be(true)
    end
  end

  it "does not persist a close while the feature is off for the seller" do
    Feature.deactivate_user(:close_membership_tier_to_new_buyers, seller)

    post :update, params: editor_save_params(closed_to_new_purchases: true), as: :json

    expect(response).to be_successful
    expect(tier.reload.closed_to_new_purchases?).to be(false)
  end
end
