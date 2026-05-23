# frozen_string_literal: true

require "test_helper"

class ProductReviewVideosStreamingUrlsControllerTest < ActionController::TestCase
  self.described_class = ProductReviewVideos::StreamingUrlsController
  tests ProductReviewVideos::StreamingUrlsController



  context_ ProductReviewVideos::StreamingUrlsController, type: :controller do
    let(:seller) { create(:user) }
    let(:purchaser) { create(:user) }

    let(:link) { create(:product, user: seller) }
    let(:purchase) { create(:purchase, seller:, purchaser:, link:) }

    let(:product_review) { create(:product_review, purchase:) }
    let(:product_review_video) { create(:product_review_video, product_review:) }

  context_ "GET #index" do
  context_ "when the product review video is approved" do
        before { product_review_video.approved! }

  test "returns the correct media URLs" do
          freeze_time do
            get :index, params: {
              product_review_video_id: product_review_video.external_id
            }, format: :json

            expect(response).to have_http_status(:ok)
            expect(response.parsed_body[:streaming_urls]).to eq(
              [
                product_review_video_stream_path(
                  product_review_video.external_id,
                  format: :smil
                ),
                product_review_video.video_file.signed_download_url
              ]
            )
          end
        end
      end

  context_ "when the product review video is not approved" do
        before { product_review_video.pending_review! }

  context_ "when the user is not logged in" do
  test "returns unauthorized status" do
            get :index, params: {
              product_review_video_id: product_review_video.external_id
            }, format: :json

            expect(response).to have_http_status(:unauthorized)
          end
        end

  context_ "when a valid purchase email digest is provided" do
  test "returns a successful response" do
            get :index, params: {
              product_review_video_id: product_review_video.external_id,
              purchase_email_digest: purchase.email_digest
            }, format: :json

            expect(response).to have_http_status(:ok)
          end
        end

  context_ "when the user is the seller" do
          before { sign_in(seller) }

  test "returns a successful response" do
            get :index, params: {
              product_review_video_id: product_review_video.external_id,
            }, format: :json

            expect(response).to have_http_status(:ok)
          end
        end

  context_ "when the user is the purchaser" do
          before { sign_in(purchaser) }

  test "returns a successful response" do
            get :index, params: {
              product_review_video_id: product_review_video.external_id,
            }, format: :json

            expect(response).to have_http_status(:ok)
          end
        end
      end

  context_ "when the product review video is not found" do
  test "raises a RecordNotFound error" do
          expect do
            get :index, params: {
              product_review_video_id: "nonexistent_id"
            }, format: :json
          end.to raise_error(ActiveRecord::RecordNotFound)
        end
      end
    end
  end
end
