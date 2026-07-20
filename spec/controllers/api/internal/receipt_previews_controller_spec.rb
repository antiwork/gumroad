# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe Api::Internal::ReceiptPreviewsController do
  render_views

  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller, name: "Sample product", price_cents: 500) }

  include_context "with user signed in as admin for seller"

  describe "GET show" do
    it "returns the subject and rendered body from the same preview response" do
      get :show, params: { product_id: product.unique_permalink }

      expect(response).to be_successful
      json = response.parsed_body
      # Subject must be the presenter's real mail subject for this purchase preview —
      # sourced server-side alongside the body so the two cannot disagree.
      expect(json["subject"]).to eq("You bought Sample product!")
      expect(json["html"]).to include("Sample product")
    end

    it "uses the free-product subject for a free product" do
      free = create(:product, user: seller, name: "Freebie", price_cents: 0, customizable_price: true)

      get :show, params: { product_id: free.unique_permalink }

      expect(response).to be_successful
      expect(response.parsed_body["subject"]).to eq("You got Freebie!")
    end

    it "returns a JSON error for an invalid preview" do
      allow_any_instance_of(PurchasePreview).to receive(:valid?).and_return(false)

      get :show, params: { product_id: product.unique_permalink }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to have_key("error")
    end
  end
end
