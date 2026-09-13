# frozen_string_literal: true

require "spec_helper"

describe ThumbnailsController do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }

  describe "POST create" do
    let(:request_params) do
      blob = ActiveStorage::Blob.create_and_upload!(
        io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "smilie.png"), "image/png"),
        filename: "smilie.png"
      )
      blob.analyze
      { link_id: product.unique_permalink, thumbnail: { signed_blob_id: blob.signed_id }, format: :json }
    end

    context "when the current user is a collaborator on the product" do
      let(:affiliate_user) { create(:user) }
      let!(:collaborator) { create(:collaborator, seller:, affiliate_user:, products: [product]) }

      before { sign_in affiliate_user }

      it "attaches the thumbnail" do
        expect do
          post :create, params: request_params
        end.to change { product.reload.thumbnail.present? }.from(false).to(true)

        expect(response).to have_http_status(:success)
        expect(response.parsed_body["success"]).to eq(true)
      end
    end

    context "when the current user neither owns nor collaborates on the product" do
      before { sign_in create(:user) }

      it "does not find the product" do
        expect do
          post :create, params: request_params
        end.to raise_error(ActionController::RoutingError, "Not Found")

        expect(product.reload.thumbnail).to be_blank
      end
    end
  end

  describe "DELETE destroy" do
    let!(:thumbnail) { create(:thumbnail, product:) }

    context "when the current user is a collaborator on the product" do
      let(:affiliate_user) { create(:user) }
      let!(:collaborator) { create(:collaborator, seller:, affiliate_user:, products: [product]) }

      before { sign_in affiliate_user }

      it "deletes the thumbnail" do
        delete :destroy, params: { link_id: product.unique_permalink, id: thumbnail.guid, format: :json }

        expect(response).to have_http_status(:success)
        expect(response.parsed_body["success"]).to eq(true)
        expect(thumbnail.reload).not_to be_alive
      end
    end
  end
end
