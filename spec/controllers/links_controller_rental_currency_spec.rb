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

  describe "when the rental price is outside the new currency's range" do
    def expect_rejected_with(message)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error_message"]).to eq(message)
      product.reload
      expect(product.price_currency_type).to eq("usd")
      expect(product.default_price_cents).to eq(9_900)
      expect(product.rental).to eq(price_cents: 4_900, rent_only: false)
    end

    it "names the rental minimum even when the visible buy price is well above it, and saves nothing" do
      product

      expect do
        post :update, params: editor_save_params(price_currency_type: "inr", price_cents: 10_000_00), as: :json
      end.not_to change { Price.count }

      expect_rejected_with("Your changes weren't saved. Your $49 rental price would become ₹49, below the ₹73 minimum. " \
                           "Switch back to the original currency, or contact support for help.")
    end

    it "shows the saved rental price in its own currency and the new one in a currency without cents" do
      eur_product = create(:product, user: seller, price_currency_type: "eur", price_cents: 9_900,
                                     purchase_type: :buy_and_rent, rental_price_cents: 4_900)

      post :update, params: editor_save_params(id: eur_product.unique_permalink, name: eur_product.name,
                                               price_currency_type: "vnd", price_cents: 1_000_000), as: :json

      expect(response.parsed_body["error_message"]).to eq("Your changes weren't saved. Your €49 rental price would become 4,900 ₫, " \
                                                         "below the 25,618 ₫ minimum. " \
                                                         "Switch back to the original currency, or contact support for help.")
      expect(eur_product.reload.price_currency_type).to eq("eur")
      expect(eur_product.rental).to eq(price_cents: 4_900, rent_only: false)
    end

    it "names the unverified seller maximum" do
      product.update!(rental_price_cents: 4_900_00)
      currencies = Redis::Namespace.new(:currencies, redis: $redis)
      currencies.set("EUR", "0.81127")

      post :update, params: editor_save_params(price_currency_type: "eur", price_cents: 8_900), as: :json

      expect(response.parsed_body["error_message"]).to eq("Your changes weren't saved. Your $4,900 rental price would become €4,900, " \
                                                         "worth more than the $5,000 USD limit for your account. " \
                                                         "Switch back to the original currency, or contact support for help.")
      expect(product.reload.price_currency_type).to eq("usd")
      expect(product.rental).to eq(price_cents: 4_900_00, rent_only: false)
    ensure
      currencies&.del("EUR")
    end
  end

  describe "saves the rental check leaves alone" do
    it "keeps the existing minimum error for a buy price below the new currency's minimum" do
      product.update!(purchase_type: :buy_only)

      post :update, params: editor_save_params(price_currency_type: "inr", price_cents: 49_00), as: :json

      expect(response.parsed_body["error_message"]).to eq("Sorry, a product must be at least ₹73.")
    end

    it "keeps the existing minimum error for a rent-only price below the new currency's minimum" do
      product.update!(purchase_type: :rent_only)

      post :update, params: editor_save_params(price_currency_type: "inr", price_cents: 49_00), as: :json

      expect(response.parsed_body["error_message"]).to eq("Sorry, a product must be at least ₹73.")
      expect(product.reload.price_currency_type).to eq("usd")
    end

    it "carries a zero rental price" do
      product.update!(rental_price_cents: 0)

      post :update, params: editor_save_params(price_currency_type: "inr", price_cents: 10_000_00), as: :json

      expect(response).to be_successful
      expect(product.reload.rental).to eq(price_cents: 0, rent_only: false)
    end

    it "changes the currency of a buy-and-rent product with no rental price in its current currency" do
      product.prices.alive.is_rental.each(&:mark_deleted!)

      post :update, params: editor_save_params(price_currency_type: "inr", price_cents: 10_000_00), as: :json

      expect(response).to be_successful
      expect(product.reload.price_currency_type).to eq("inr")
      expect(product.prices.alive.is_rental).to be_empty
    end

    it "leaves the rental price row alone when the currency stays the same" do
      rental_price = product.prices.alive.is_rental.sole

      post :update, params: editor_save_params(price_cents: 9_500), as: :json

      expect(response).to be_successful
      expect(product.reload.default_price_cents).to eq(9_500)
      expect(product.prices.alive.is_rental.sole).to eq(rental_price)
      expect(rental_price.reload.price_cents).to eq(4_900)
    end
  end
end
