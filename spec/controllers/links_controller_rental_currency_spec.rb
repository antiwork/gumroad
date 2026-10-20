# frozen_string_literal: true

require "spec_helper"

describe LinksController, type: :controller do
  let(:seller) { create(:user) }
  let(:product) do
    create(:product, user: seller, price_currency_type: "usd", price_cents: 9_900,
                     purchase_type: :buy_and_rent, rental_price_cents: 4_900)
  end

  before { sign_in seller }

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
      rich_content_provenance_version: 2,
    }.merge(overrides)
  end

  it "keeps the rental offer when the editor changes a buy-and-rent product's currency" do
    post :update, params: editor_save_params(price_currency_type: "eur", price_cents: 8_900), as: :json

    expect(response).to be_successful
    product.reload
    expect(product.price_currency_type).to eq("eur")
    expect(product.buy_and_rent?).to be(true)
    expect(product.default_price_cents).to eq(8_900)
    expect(product.rental).to eq(price_cents: 4_900, rent_only: false)
  end

  it "carries the current rental price over an older rental price in the new currency" do
    create(:price, link: product, currency: "eur", is_rental: true, price_cents: 3_000)

    post :update, params: editor_save_params(price_currency_type: "eur", price_cents: 8_900), as: :json

    expect(response).to be_successful
    expect(product.reload.rental).to eq(price_cents: 4_900, rent_only: false)
  end
end
