# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/collaborator_access"
require "inertia_rails/rspec"

describe Products::ReceiptController, inertia: true do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }

  include_context "with user signed in as admin for seller"

  describe "GET edit" do
    it_behaves_like "authorize called for action", :get, :edit do
      let(:record) { product }
      let(:request_params) { { product_id: product.unique_permalink } }
    end

    it "renders the Products/Receipt/Edit component with expected props" do
      get :edit, params: { product_id: product.unique_permalink }

      expect(response).to be_successful
      expect(inertia.component).to eq("Products/Receipt/Edit")
      expect(inertia.props.keys).to include(:id, :unique_permalink, :product, :seller)
      expect(inertia.props[:id]).to eq(product.external_id)
      expect(inertia.props[:unique_permalink]).to eq(product.unique_permalink)
      expect(inertia.props[:product]).to be_a(Hash)
      expect(inertia.props[:product][:name]).to eq(product.name)
      expect(inertia.props[:product][:custom_receipt_text]).to eq(product.custom_receipt_text)
    end
  end

  describe "PATCH update" do
    let(:params) do
      {
        product_id: product.unique_permalink,
        product: {
          custom_receipt_text: "Thanks for buying!",
          custom_view_content_button_text: "Download Now"
        }
      }
    end

    context "with Inertia request" do
      before { request.headers["X-Inertia"] = "true" }

      it_behaves_like "collaborator can access", :put, :update do
        let(:request_params) { params }
        let(:response_status) { 303 }
      end

      it "updates the receipt info and redirects" do
        put :update, params: params

        expect(response).to redirect_to(edit_product_receipt_path(product.unique_permalink))
        expect(flash[:notice]).to eq("Changes saved!")
        expect(product.reload.custom_receipt_text).to eq("Thanks for buying!")
        expect(product.custom_view_content_button_text).to eq("Download Now")
      end
    end

  end
end
