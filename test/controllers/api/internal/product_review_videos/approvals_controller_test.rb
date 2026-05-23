# frozen_string_literal: true

require "test_helper"
require "shared_examples/authentication_required"

class ApiInternalProductReviewVideosApprovalsControllerTest < ActionController::TestCase
  self.described_class = Api::Internal::ProductReviewVideos::ApprovalsController
  tests Api::Internal::ProductReviewVideos::ApprovalsController



  context_ Api::Internal::ProductReviewVideos::ApprovalsController do
    let!(:seller) { create(:user) }
    let(:buyer) { create(:user) }
    let(:product) { create(:product, user: seller) }
    let(:purchase) { create(:purchase, link: product, seller:) }
    let(:product_review) { create(:product_review, purchase:, link: product) }
    let(:product_review_video) { create(:product_review_video, product_review:, approval_status: :pending_review) }

  context_ "POST create" do
      it_behaves_like "authentication required for action", :post, :create do
        let(:request_params) { { product_review_video_id: product_review_video.external_id } }
      end

  context_ "when logged in as the seller" do
        before { sign_in seller }

  test "approves the video when found" do
          expect do
            post :create, params: { product_review_video_id: product_review_video.external_id }, format: :json

            expect(response).to have_http_status(:ok)
          end.to change { product_review_video.reload.approval_status }.from("pending_review").to("approved")
        end

  test "returns not found for non-existent product review video" do
          expect do
            post :create, params: { product_review_video_id: "non-existent-id" }, format: :json
          end.to raise_error(ActiveRecord::RecordNotFound)
        end

  test "returns not found when the product review video has been soft-deleted" do
          product_review_video.mark_deleted!

          expect do
            post :create, params: { product_review_video_id: product_review_video.external_id }, format: :json
          end.to raise_error(ActiveRecord::RecordNotFound)

          expect(product_review_video.reload.approved?).to eq(false)
        end
      end

  context_ "when logged in as a user without permission" do
        let(:different_user) { create(:user) }

        before { sign_in different_user }

  test "returns unauthorized when the user does not have permission to approve the video" do
          post :create, params: { product_review_video_id: product_review_video.external_id }, format: :json

          expect(response).to have_http_status(:unauthorized)
          expect(product_review_video.reload.approved?).to eq(false)
        end
      end
    end
  end
end
