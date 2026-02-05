# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe Products::Edit::ProductController, inertia: true do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }

  include_context "with user signed in as admin for seller"

  describe "GET show" do
    it "renders the Products/Edit/Product Inertia component with expected props" do
      get :show, params: { id: product.unique_permalink }
      expect(response).to be_successful
      expect(inertia.component).to eq("Products/Edit/Product")
      expect(inertia.props[:id]).to eq(product.external_id)
      expect(inertia.props[:unique_permalink]).to eq(product.unique_permalink)
      expect(inertia.props[:product]).to be_a(Hash)
      expect(inertia.props[:product][:name]).to eq(product.name)
    end

    context "when product is a bundle" do
      let(:bundle) { create(:product, :bundle, user: seller) }

      it "redirects to bundle path" do
        get :show, params: { id: bundle.unique_permalink }
        expect(response).to redirect_to(bundle_path(bundle.external_id))
      end
    end

    context "when the product doesn't exist" do
      it "returns 404" do
        expect { get :show, params: { id: "nonexistent" } }.to raise_error(ActionController::RoutingError)
      end
    end
  end

  describe "PUT update" do
    let(:product) { create(:product_with_pdf_file, user: seller) }

    it_behaves_like "authorize called for action", :put, :update do
      let(:record) { product }
      let(:request_params) { { id: product.unique_permalink } }
    end

    context "with valid params" do
      it "updates the product and redirects" do
        expect do
          put :update, params: {
            id: product.unique_permalink,
            name: "New Product Name",
            description: "New description"
          }
          product.reload
        end.to change { product.name }.to("New Product Name")

        expect(response).to redirect_to(products_edit_product_path(product.unique_permalink))
        expect(flash[:notice]).to eq("Changes saved successfully!")
      end
    end

    context "when there is a validation error" do
      it "returns the error message" do
        expect do
          put :update, params: {
            id: product.unique_permalink,
            custom_permalink: "*"
          }
        end.to not_change { product.reload.custom_permalink }

        expect(response).to redirect_to(products_edit_product_path(product.unique_permalink))
        expect(flash[:alert]).to eq("Custom permalink is invalid")
      end
    end

    context "with validation error" do
      it "returns the error message" do
        expect do
          put :update, params: {
            id: product.unique_permalink,
            custom_permalink: "*"
          }
        end.to not_change { product.reload.custom_permalink }

        expect(response).to redirect_to(products_edit_product_path(product.unique_permalink))
        expect(flash[:alert]).to eq("Custom permalink is invalid")
      end
    end

    context "when product is a bundle" do
      let(:bundle) { create(:product, :bundle, user: seller) }

      it "redirects to bundle path" do
        get :show, params: { id: bundle.unique_permalink }
        expect(response).to redirect_to(bundle_path(bundle.external_id))
      end
    end
  end
end
