# frozen_string_literal: true

require "spec_helper"

# Regression coverage for gumroad-private#3914.
#
# The editor writes the version rows after the first save in the same request, so a $0-base
# product gaining its first paid version there ran the customizable-price guard while the paid
# version was still missing, and it forced the flag back on over the seller's explicit off.
describe LinksController, type: :controller do
  let(:seller) { create(:user) }
  let!(:product) { create(:product, user: seller, price_cents: 0) }

  before { sign_in seller }

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

  it "keeps the switch off when the same save adds the first paid version" do
    expect(product.reload.customizable_price).to be(true)

    post :update, params: editor_save_params(
      variants: [
        { id: nil, client_id: "new-version", name: "Paid checklist", price_difference_cents: 99, rich_content: [] }
      ]
    ), as: :json

    expect(response).to be_successful
    expect(product.alive_variants.map(&:price_difference_cents)).to eq([99])
    expect(product.reload.customizable_price).to be(false)
  end

  it "keeps the stored switch when a save that adds the first paid version omits it" do
    expect(product.reload.customizable_price).to be(true)

    post :update, params: editor_save_params(
      variants: [
        { id: nil, client_id: "new-version", name: "Paid checklist", price_difference_cents: 99, rich_content: [] }
      ]
    ).except(:customizable_price), as: :json

    expect(response).to be_successful
    expect(product.alive_variants.map(&:price_difference_cents)).to eq([99])
    expect(product.reload.customizable_price).to be(true)
  end

  it "still forces pay-what-you-want on when the save adds no paid version" do
    post :update, params: editor_save_params, as: :json

    expect(response).to be_successful
    expect(product.reload.customizable_price).to be(true)
  end

  it "still forces pay-what-you-want on when the save adds only a free version" do
    post :update, params: editor_save_params(
      variants: [
        { id: nil, client_id: "new-version", name: "Free version", price_difference_cents: 0, rich_content: [] }
      ]
    ), as: :json

    expect(response).to be_successful
    expect(product.reload.customizable_price).to be(true)
  end
end
