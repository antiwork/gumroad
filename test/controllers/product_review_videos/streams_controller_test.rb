# frozen_string_literal: true

require "test_helper"

class ProductReviewVideosStreamsControllerTest < ActionController::TestCase
  self.described_class = ProductReviewVideos::StreamsController
  tests ProductReviewVideos::StreamsController



  context_ ProductReviewVideos::StreamsController do
  context_ "GET show" do
      let(:smil_xml) { '<smil><body><switch><video src="sample.mp4" /></switch></body></smil>' }
      let!(:product_review_video) { create(:product_review_video) }

  context_ "when the video exists" do
  test "returns smil content when format is smil" do
          allow_any_instance_of(VideoFile).to receive(:smil_xml).and_return(smil_xml)

          get :show, params: { product_review_video_id: product_review_video.external_id, format: :smil }

          expect(response).to have_http_status(:success)
          expect(response.content_type).to include("application/smil+xml")
          expect(response.body).to eq(smil_xml)
        end

  test "returns 406 for non-smil formats" do
          expect do
            get :show, params: { product_review_video_id: product_review_video.external_id, format: :html }
          end.to raise_error(ActionController::UnknownFormat)
        end

  test "returns 406 when no format is specified" do
          expect do
            get :show, params: { product_review_video_id: product_review_video.external_id }
          end.to raise_error(ActionController::UnknownFormat)
        end
      end

  context_ "when the video does not exist" do
  test "returns 404 for non-existent video" do
          expect do
            get :show, params: { product_review_video_id: "non-existent-id", format: :smil }
          end.to raise_error(ActiveRecord::RecordNotFound)
        end
      end

  context_ "when the video is soft deleted" do
        before do
          product_review_video.mark_deleted!
        end

  test "returns 404 for soft deleted video" do
          expect do
            get :show, params: { product_review_video_id: product_review_video.external_id, format: :smil }
          end.to raise_error(ActiveRecord::RecordNotFound)
        end
      end
    end
  end
end
