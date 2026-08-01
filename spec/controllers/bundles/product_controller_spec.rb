# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe Bundles::ProductController, inertia: true do
  let(:seller) { create(:named_seller, :eligible_for_service_products) }
  let(:bundle) { create(:product, :bundle, user: seller, price_cents: 2000, price_currency_type: "usd") }

  include_context "with user signed in as admin for seller"

  describe "GET edit" do
    it "renders the bundle's display currency so the editor's selector opens on it" do
      bundle.price_currency_type = "eur"
      bundle.price_cents = 2000
      bundle.save!

      get :edit, params: { bundle_id: bundle.external_id }

      expect(response).to be_successful
      expect(inertia.component).to eq("Bundles/Product/Edit")
      expect(inertia.props[:currency_type]).to eq("eur")
    end
  end

  describe "PUT update" do
    it_behaves_like "authorize called for action", :put, :update do
      let(:policy_klass) { LinkPolicy }
      let(:record) { bundle }
      let(:request_params) { { bundle_id: bundle.external_id } }
    end

    it "changes the bundle's display currency" do
      put :update, params: { bundle_id: bundle.external_id, price_currency_type: "eur", price_cents: 2000 }

      expect(bundle.reload.price_currency_type).to eq("eur")
    end

    # The seller's actual path: they touch only the currency dropdown, so the
    # form re-sends the unchanged amount. The Price row is filed under whatever
    # currency is set when `price_cents=` runs, so if the amount landed first
    # there would be no row in the new currency and the save would fail on a
    # blank default price.
    it "carries the existing amount into the new currency when the amount is unchanged" do
      put :update, params: { bundle_id: bundle.external_id, price_currency_type: "eur", price_cents: 2000 }

      bundle.reload
      expect(bundle.price_currency_type).to eq("eur")
      expect(bundle.price_cents).to eq(2000)
      expect(bundle.alive_prices.is_buy.where(currency: "eur").last&.price_cents).to eq(2000)
    end

    it "carries the existing amount across when the request omits the price entirely" do
      put :update, params: { bundle_id: bundle.external_id, price_currency_type: "eur" }

      bundle.reload
      expect(bundle.price_currency_type).to eq("eur")
      expect(bundle.price_cents).to eq(2000)
    end

    # The regression this endpoint's ordering exists for: `price_cents=` files a
    # Price row scoped to price_currency_type as it stands at that moment, so
    # assigning the amount first leaves the new price under the old currency and
    # the bundle reads back the stale one. Reverting the ordering reddens here.
    it "files the submitted amount under the new currency, not the old one" do
      put :update, params: { bundle_id: bundle.external_id, price_currency_type: "eur", price_cents: 3500 }

      bundle.reload
      expect(bundle.price_currency_type).to eq("eur")
      expect(bundle.alive_prices.is_buy.where(currency: "eur").last&.price_cents).to eq(3500)
      expect(bundle.price_cents).to eq(3500)
    end

    # Non-default currency on purpose: with a usd fixture this is green whether
    # the omit branch preserves the value or resets it to the seller default.
    it "leaves the currency alone when the request omits it" do
      bundle.update!(price_currency_type: "gbp", price_cents: 2000)

      put :update, params: { bundle_id: bundle.external_id, price_cents: 2500 }

      expect(bundle.reload.price_currency_type).to eq("gbp")
      expect(bundle.price_cents).to eq(2500)
    end

    # The form re-sends the current default_offer_code_id on every save, so
    # without the unchanged-id short circuit in update_default_offer_code a
    # universal currency-scoped code fails the whole save with the unrelated
    # "Offer code must apply to this product".
    it "still changes the currency when the resent default offer code is universal and currency-scoped" do
      offer_code = create(:universal_offer_code, user: seller, amount_cents: 100, currency_type: "usd", code: "univ")
      bundle.update!(default_offer_code: offer_code)

      put :update, params: {
        bundle_id: bundle.external_id, price_currency_type: "eur", price_cents: 2000,
        default_offer_code_id: offer_code.external_id
      }

      bundle.reload
      expect(bundle.price_currency_type).to eq("eur")
      expect(bundle.default_offer_code).to be_nil
    end

    # A product-specific fixed-amount code is not detached or currency-checked
    # anywhere on this path, so without the warning the seller's discount stops
    # quoting with nothing said. Mirrors LinksController#update.
    context "when a fixed-amount offer code no longer matches the new currency" do
      let!(:offer_code) { create(:offer_code, user: seller, products: [bundle], code: "tenoff", amount_cents: 500, currency_type: "usd") }

      it "warns the seller and names the code" do
        put :update, params: { bundle_id: bundle.external_id, price_currency_type: "eur", price_cents: 2000 }

        expect(bundle.reload.price_currency_type).to eq("eur")
        expect(flash[:warning]).to include("tenoff")
        expect(flash[:warning]).to include("will not apply at checkout")
        expect(flash[:notice]).to be_blank
      end

      it "stays quiet when the currency did not move" do
        put :update, params: { bundle_id: bundle.external_id, price_cents: 2500 }

        expect(flash[:warning]).to be_blank
        expect(flash[:notice]).to eq("Changes saved!")
      end
    end

    it "stays quiet on a currency change when no offer code is attached" do
      put :update, params: { bundle_id: bundle.external_id, price_currency_type: "eur", price_cents: 2000 }

      expect(bundle.reload.price_currency_type).to eq("eur")
      expect(flash[:warning]).to be_blank
      expect(flash[:notice]).to eq("Changes saved!")
    end

    # An unsupported currency is caught by the model's own
    # `price_must_be_within_range`, not by anything added here — these pin that
    # it surfaces to the seller as a flash alert and rolls the whole update back.
    it "rejects a currency Gumroad does not price in" do
      put :update, params: { bundle_id: bundle.external_id, price_currency_type: "xyz", price_cents: 2000 }

      expect(flash[:alert]).to eq("'xyz' is not a supported currency.")
      expect(bundle.reload.price_currency_type).to eq("usd")
    end

    it "does not persist any other submitted change when the currency is rejected" do
      put :update, params: { bundle_id: bundle.external_id, name: "Renamed", price_currency_type: "xyz" }

      expect(bundle.reload.name).not_to eq("Renamed")
    end
  end
end
