# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProductReview::UpdateService do
  let(:purchaser) { create(:user) }
  let(:purchase) { create(:purchase, purchaser:) }
  let(:product_review) do
    create(:product_review, purchase:, rating: 3, message: "Original message")
  end

  describe "#update" do
    it "returns the product review" do
      returned_product_review = described_class
        .new(product_review, rating: 5, message: "Updated message")
        .update

      expect(returned_product_review).to eq(product_review)
    end

    it "updates the product review with the new rating and message" do
      expect do
        described_class.new(product_review, rating: 5, message: "Updated message").update
      end.to change { product_review.rating }.from(3).to(5)
        .and change { product_review.message }.from("Original message").to("Updated message")
    end

    context "with video_options" do
      let(:video_url) { "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/video.mp4" }
      let(:blob) do
        ActiveStorage::Blob.create_and_upload!(
          io: fixture_file_upload("test-small.jpg"),
          filename: "test-small.jpg",
          content_type: "image/jpeg"
        )
      end

      context "when create option with url is provided" do
        let!(:existing_pending_video) do
          create(
            :product_review_video,
            :pending_review,
            product_review: product_review
          )
        end

        it "creates a new video associated with the product review" do
          expect do
            described_class.new(
              product_review,
              rating: 4,
              message: "With video",
              video_options: {
                create: { url: video_url, thumbnail_signed_id: blob.signed_id }
              }
            ).update
          end.to change { product_review.videos.count }.by(1)
            .and change { existing_pending_video.reload.deleted? }.from(false).to(true)

          new_video = product_review.videos.last
          expect(new_video.approval_status).to eq("pending_review")
          expect(new_video.video_file.url).to eq(video_url)
          expect(new_video.video_file.thumbnail.signed_id).to eq(blob.signed_id)
        end
      end

      context "when destroy option with id is provided" do
        let!(:video) { create(:product_review_video, product_review:) }

        it "marks the video as deleted" do
          expect do
            described_class.new(
              product_review,
              rating: 4,
              message: "Remove video",
              video_options: { destroy: { id: video.external_id } }
            ).update
          end.to change { video.reload.deleted? }.from(false).to(true)
        end
      end
    end
  end
end
