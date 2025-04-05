# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authentication_required"

describe Api::Internal::ProductReviewVideos::RejectionsController do
  let!(:seller) { create(:user) }
  let(:buyer) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:purchase) { create(:purchase, link: product, seller:) }
  let(:product_review) { create(:product_review, purchase:, link: product) }
  let(:product_review_video) { create(:product_review_video, product_review:, approval_status: :pending_review) }

  describe "POST create" do
    it_behaves_like "authentication required for action", :post, :create do
      let(:request_params) { { product_review_video_id: product_review_video.external_id } }
    end

    context "when logged in as the seller" do
      before { sign_in seller }

      it "rejects the video when found" do
        expect do
          post :create, params: { product_review_video_id: product_review_video.external_id }, format: :json

          expect(response).to have_http_status(:ok)
        end.to change { product_review_video.reload.approval_status }.from("pending_review").to("rejected")
      end

      it "returns not found for non-existent product review video" do
        expect do
          post :create, params: { product_review_video_id: "non-existent-id" }, format: :json
        end.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "returns not found when the product review video has been soft-deleted" do
        product_review_video.mark_deleted!

        expect do
          post :create, params: { product_review_video_id: product_review_video.external_id }, format: :json
        end.to raise_error(ActiveRecord::RecordNotFound)

        expect(product_review_video.reload.rejected?).to eq(false)
      end
    end

    context "when logged in as a user without permission" do
      let(:different_user) { create(:user) }

      before { sign_in different_user }

      it "returns unauthorized when the user does not have permission to reject the video" do
        post :create, params: { product_review_video_id: product_review_video.external_id }, format: :json

        expect(response).to have_http_status(:unauthorized)
        expect(product_review_video.reload.rejected?).to eq(false)
      end
    end
  end
end
