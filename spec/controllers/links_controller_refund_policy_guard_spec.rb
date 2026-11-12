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
end
