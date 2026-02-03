# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe Products::ShareController, inertia: true do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }

  include_context "with user signed in as admin for seller"

  describe "GET edit" do
    it_behaves_like "authorize called for action", :get, :edit do
      let(:record) { product }
      let(:request_params) { { product_id: product.unique_permalink } }
    end

    context "when product is published" do
      before { product.publish! }

      it "renders the Products/Share/Edit component with expected props" do
        get :edit, params: { product_id: product.unique_permalink }

        expect(response).to be_successful
        expect(inertia.component).to eq("Products/Share/Edit")
        expect(inertia.props.keys).to include(:id, :unique_permalink, :product, :seller)
        expect(inertia.props[:id]).to eq(product.external_id)
        expect(inertia.props[:unique_permalink]).to eq(product.unique_permalink)
        expect(inertia.props[:product]).to be_a(Hash)
        expect(inertia.props[:product][:name]).to eq(product.name)
        expect(inertia.props[:product][:is_published]).to eq(!product.draft && product.alive?)
      end
    end

    context "when product is not published" do
      before { product.update!(draft: true) }

      it "redirects to product or content tab with alert" do
        get :edit, params: { product_id: product.unique_permalink }

        expect(response).to redirect_to(edit_product_content_path(product.unique_permalink))
        expect(flash[:alert]).to include("publish")
      end
    end
  end

  describe "PATCH update" do
    let(:params) do
      {
        product_id: product.unique_permalink,
        product: {
          is_adult: true,
          display_product_reviews: false
        }
      }
    end

    context "with Inertia request" do
      before { request.headers["X-Inertia"] = "true" }

      it "updates the share info and redirects" do
        put :update, params: params

        expect(response).to redirect_to(edit_product_share_path(product.unique_permalink))
        expect(flash[:notice]).to eq("Changes saved!")
        expect(product.reload.is_adult).to be(true)
        expect(product.display_product_reviews).to be(false)
      end

      it "sets is_adult to true when product is_adult is true" do
        product.update!(is_adult: false)
        put :update, params: {
          product_id: product.unique_permalink,
          product: { is_adult: true }
        }
        expect(product.reload.is_adult).to be(true)
        expect(response).to redirect_to(edit_product_share_path(product.unique_permalink))
      end

      it "sets is_adult to false when product is_adult is false" do
        product.update!(is_adult: true)
        put :update, params: {
          product_id: product.unique_permalink,
          product: { is_adult: false }
        }
        expect(product.reload.is_adult).to be(false)
        expect(response).to redirect_to(edit_product_share_path(product.unique_permalink))
      end

      it "sets display_product_reviews to true when display_product_reviews is true" do
        product.update!(display_product_reviews: false)
        put :update, params: {
          product_id: product.unique_permalink,
          product: { display_product_reviews: true }
        }
        expect(product.reload.display_product_reviews).to be(true)
        expect(response).to redirect_to(edit_product_share_path(product.unique_permalink))
      end

      it "sets display_product_reviews to false when display_product_reviews is false" do
        product.update!(display_product_reviews: true)
        put :update, params: {
          product_id: product.unique_permalink,
          product: { display_product_reviews: false }
        }
        expect(product.reload.display_product_reviews).to be(false)
        expect(response).to redirect_to(edit_product_share_path(product.unique_permalink))
      end

      context "when unpublishing" do
        before { product.publish! }

        it "unpublishes and redirects to content tab" do
          put :update, params: {
            product_id: product.unique_permalink,
            unpublish: true
          }

          expect(response).to redirect_to(edit_product_content_path(product.unique_permalink))
          expect(flash[:notice]).to eq("Unpublished!")
          expect(product.reload.purchase_disabled_at).to be_present
        end
      end
    end

  end
end
