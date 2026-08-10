# frozen_string_literal: true

require "spec_helper"

describe ProductReviewVideos::StreamsController do
  let(:smil_xml) { '<smil><body><switch><video src="sample.mp4" /></switch></body></smil>' }
  let(:seller) { create(:user) }
  let(:purchaser) { create(:user) }
  let(:link) { create(:product, user: seller) }
  let(:purchase) { create(:purchase, seller:, purchaser:, link:) }
  let(:product_review) { create(:product_review, purchase:) }
  let(:product_review_video) { create(:product_review_video, product_review:) }

  before { allow_any_instance_of(VideoFile).to receive(:smil_xml).and_return(smil_xml) }

  describe "GET show" do
    context "when the video is approved" do
      before { product_review_video.approved! }

      it "returns smil content when format is smil, with no auth required" do
        get :show, params: { product_review_video_id: product_review_video.external_id, format: :smil }

        expect(response).to have_http_status(:success)
        expect(response.content_type).to include("application/smil+xml")
        expect(response.body).to eq(smil_xml)
      end

      it "returns 406 for non-smil formats" do
        expect do
          get :show, params: { product_review_video_id: product_review_video.external_id, format: :html }
        end.to raise_error(ActionController::UnknownFormat)
      end

      it "returns 406 when no format is specified" do
        expect do
          get :show, params: { product_review_video_id: product_review_video.external_id }
        end.to raise_error(ActionController::UnknownFormat)
      end
    end

    context "when the video is pending review or rejected" do
      before { product_review_video.pending_review! }

      it "returns 401 when the request has no session and no matching purchase digest" do
        get :show, params: { product_review_video_id: product_review_video.external_id, format: :smil }

        expect(response).to have_http_status(:unauthorized)
        expect(response.body).not_to eq(smil_xml)
      end

      it "returns 401 for a mismatched purchase_email_digest" do
        get :show, params: {
          product_review_video_id: product_review_video.external_id,
          purchase_email_digest: "wrong-digest",
          format: :smil
        }

        expect(response).to have_http_status(:unauthorized)
        expect(response.body).not_to eq(smil_xml)
      end

      it "streams when the purchase_email_digest matches the reviewing purchase" do
        get :show, params: {
          product_review_video_id: product_review_video.external_id,
          purchase_email_digest: purchase.email_digest,
          format: :smil
        }

        expect(response).to have_http_status(:success)
        expect(response.body).to eq(smil_xml)
      end

      it "streams for the purchaser" do
        sign_in(purchaser)

        get :show, params: { product_review_video_id: product_review_video.external_id, format: :smil }

        expect(response).to have_http_status(:success)
      end

      it "streams for the seller" do
        sign_in(seller)

        get :show, params: { product_review_video_id: product_review_video.external_id, format: :smil }

        expect(response).to have_http_status(:success)
      end

      it "returns 401 for an unrelated signed-in user" do
        sign_in(create(:user))

        get :show, params: { product_review_video_id: product_review_video.external_id, format: :smil }

        expect(response).to have_http_status(:unauthorized)
        expect(response.body).not_to eq(smil_xml)
      end
    end

    context "when the video does not exist" do
      it "returns 404 for non-existent video" do
        expect do
          get :show, params: { product_review_video_id: "non-existent-id", format: :smil }
        end.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "when the video is soft deleted" do
      before do
        product_review_video.approved!
        product_review_video.mark_deleted!
      end

      it "returns 404 for soft deleted video" do
        expect do
          get :show, params: { product_review_video_id: product_review_video.external_id, format: :smil }
        end.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end
end
