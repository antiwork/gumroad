# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Checkout::FormController do
  render_views

  let(:seller) { create(:named_seller) }
  let(:pundit_user) { SellerContext.new(user: seller, seller:) }

  it_behaves_like "authorize called for controller", Checkout::FormPolicy do
    let(:record) { :form }
  end

  include_context "with user signed in as admin for seller"

  describe "GET show" do
    it "returns HTTP success and renders correct inertia props" do
      get :show

      expect(response).to be_successful
      expect(assigns[:title]).to eq("Checkout form")

      expect(response.body).to include("data-page=")

      page_data_match = response.body.match(/data-page="([^"]*)"/)
      expect(page_data_match).to be_present, "Expected Inertia.js data-page attribute"

      page_data = JSON.parse(CGI.unescapeHTML(page_data_match[1]))
      expect(page_data["component"]).to eq("Checkout/Form/Show")

      props = page_data["props"]
      expect(props).to be_present

      form_props = {
        pages: props["pages"],
        user: props["user"].deep_symbolize_keys,
        cart_item: props["cart_item"],
        custom_fields: props["custom_fields"],
        card_product: props["card_product"],
        products: props["products"]
      }

      expected_props = Checkout::FormPresenter.new(pundit_user: controller.pundit_user).form_props
      expect(form_props).to eq(expected_props)
    end
  end

  describe "PUT update" do
    it "updates the seller's checkout form" do
      expect do
        put :update, params: {
          user: { display_offer_code_field: true, recommendation_type: User::RecommendationType::NO_RECOMMENDATIONS, tipping_enabled: true },
          custom_fields: [{ id: nil, type: "text", name: "Field", required: true, global: true }]
        }, as: :json
        seller.reload
      end.to change { seller.display_offer_code_field }.from(false).to(true)
      .and change { seller.tipping_enabled? }.from(false).to(true)
      .and change { seller.recommendation_type }.from(User::RecommendationType::OWN_PRODUCTS).to(User::RecommendationType::NO_RECOMMENDATIONS)
      expect(seller.custom_fields.count).to eq 1
      field = seller.custom_fields.last
      expect(field.name).to eq "Field"
      expect(field.type).to eq "text"
      expect(field.required).to eq true
      expect(field.global).to eq true

      expect(response).to be_successful
    end

    it "updates custom fields and deletes ones that aren't included" do
      field = create(:custom_field, seller:)
      create(:custom_field, seller:)
      expect do
        put :update, params: {
          custom_fields: [{ id: field.external_id, name: "New name" }]
        }, as: :json
        field.reload
      end.to change { seller.custom_fields.count }.from(2).to(1).and change { field.name }.to("New name")

      expect(response).to be_successful
    end
  end
end
