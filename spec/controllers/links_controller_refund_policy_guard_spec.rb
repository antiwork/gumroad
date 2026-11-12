# frozen_string_literal: true

require "spec_helper"

describe LinksController, type: :controller do
  let(:seller) { create(:user) }
  let!(:product) { create(:product, user: seller, price_cents: 10_000) }

  before do
    # New users get an account-level policy by default in this environment, which
    # skips the product-level write entirely.
    seller.update!(refund_policy_enabled: false)
    product.update!(product_refund_policy_enabled: true)
    create(:product_refund_policy, product:, title: "No refunds allowed", max_refund_period_in_days: 0, fine_print: "Final sale.")
    sign_in seller
  end

  def editor_save_params(overrides = {})
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

  it "keeps a live policy when the payload does not carry the enable at all" do
    post :update, params: editor_save_params, as: :json

    expect(response).to be_successful
    expect(product.reload.product_refund_policy_enabled?).to be(true)
  end

  it "keeps a live policy when the payload carries a null enable" do
    post :update, params: editor_save_params(product_refund_policy_enabled: nil), as: :json

    expect(response).to be_successful
    expect(product.reload.product_refund_policy_enabled?).to be(true)
  end

  it "stores terms submitted beside an omitted enable" do
    post :update, params: editor_save_params(refund_policy: { title: "30-day money back guarantee", max_refund_period_in_days: 30, fine_print: "Within 30 days." }), as: :json

    expect(response).to be_successful
    expect(product.reload.product_refund_policy.fine_print).to eq("Within 30 days.")
  end

  describe "baseline checks for deliberate price and refund-policy writes" do
    let(:new_terms) { { title: "30-day money back guarantee", max_refund_period_in_days: 30, fine_print: "Within 30 days." } }

    it "refuses a price that differs from the record when the tab sent no baseline" do
      post :update, params: editor_save_params(price_cents: 5_900), as: :json

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["error_code"]).to eq("stale_price_or_refund_baseline")
      expect(product.reload.price_cents).to eq(10_000)
    end

    it "applies a currency-only switch that echoes the baseline amount" do
      post :update, params: editor_save_params(price_currency_type: "eur", price_cents: 10_000, expected_price_cents: 10_000), as: :json

      expect(response).to be_successful
      expect(product.reload.price_currency_type).to eq("eur")
      expect(product.price_cents).to eq(10_000)
    end

    it "refuses a currency switch whose echoed amount is stale against the record" do
      post :update, params: editor_save_params(price_currency_type: "eur", price_cents: 9_000, expected_price_cents: 9_000), as: :json

      expect(response).to have_http_status(:conflict)
      expect(product.reload.price_currency_type).to eq("usd")
    end

    it "refuses a price whose baseline no longer matches the record" do
      post :update, params: editor_save_params(price_cents: 5_900, expected_price_cents: 9_000), as: :json

      expect(response).to have_http_status(:conflict)
      expect(product.reload.price_cents).to eq(10_000)
    end

    it "refuses an explicit refund-policy off from an old tab and applies none of the save" do
      post :update, params: editor_save_params(name: "Renamed", product_refund_policy_enabled: false), as: :json

      expect(response).to have_http_status(:conflict)
      product.reload
      expect(product.product_refund_policy_enabled?).to be(true)
      expect(product.name).not_to eq("Renamed")
    end

    it "accepts a deliberate price edit whose baseline matches the record" do
      post :update, params: editor_save_params(price_cents: 5_900, expected_price_cents: 10_000), as: :json

      expect(response).to be_successful
      expect(product.reload.price_cents).to eq(5_900)
    end

    it "accepts a deliberate refund-policy toggle whose baseline matches the record, keeping other edits" do
      post :update, params: editor_save_params(name: "Renamed", product_refund_policy_enabled: false, expected_product_refund_policy_enabled: true), as: :json

      expect(response).to be_successful
      product.reload
      expect(product.product_refund_policy_enabled?).to be(false)
      expect(product.name).to eq("Renamed")
    end

    it "keeps the stored price and policy when the tab echoes unchanged values beside a stale baseline" do
      product.update!(price_cents: 7_000)
      post :update, params: editor_save_params(name: "Renamed", price_cents: 10_000, expected_price_cents: 10_000, product_refund_policy_enabled: true, expected_product_refund_policy_enabled: true), as: :json

      expect(response).to be_successful
      product.reload
      expect(product.price_cents).to eq(7_000)
      expect(product.name).to eq("Renamed")
    end

    it "lets only the first of two saves from the same baseline change the price" do
      post :update, params: editor_save_params(price_cents: 5_900, expected_price_cents: 10_000), as: :json
      expect(response).to be_successful

      post :update, params: editor_save_params(price_cents: 8_000, expected_price_cents: 10_000), as: :json

      expect(response).to have_http_status(:conflict)
      expect(product.reload.price_cents).to eq(5_900)
    end
  end
end
