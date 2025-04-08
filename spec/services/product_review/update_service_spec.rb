# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProductReview::UpdateService do
  let(:product_review) { create(:product_review, rating: 3, message: "Original message") }

  describe "#update" do
    it "returns the product review" do
      expect(described_class.new(product_review, rating: 5, message: "Updated message").update).to eq(product_review)
    end

    it "updates the product review with the new rating and message" do
      described_class.new(product_review, rating: 5, message: "Updated message").update

      product_review.reload

      expect(product_review.rating).to eq(5)
      expect(product_review.message).to eq("Updated message")
    end

    context "with video_options" do
      let(:video_url) { "#{S3_BASE_URL}/video.mp4" }

      context "when create_by_url is provided" do
        it "creates a new video associated with the product review" do
          expect do
            described_class.new(
              product_review,
              rating: 4,
              message: "With video",
              video_options: { create_by_url: video_url }
            ).update
          end.to change { product_review.videos.count }.by(1)

          expect(product_review.videos.last.video_file.url).to eq(video_url)
        end
      end

      context "when destroy_by_external_id is provided" do
        let!(:video) { create(:product_review_video, product_review: product_review) }

        it "marks the video as deleted" do
          expect do
            described_class.new(
              product_review,
              rating: 4,
              message: "Remove video",
              video_options: { destroy_by_external_id: video.external_id }
            ).update
          end.to change { video.reload.deleted? }.from(false).to(true)
        end
      end

      context "when both create and destroy options are provided" do
        let!(:existing_video) { create(:product_review_video, product_review: product_review) }
        let(:new_video_url) { "#{S3_BASE_URL}/new-video.mp4" }

        it "removes the specified video and creates a new one" do
          expect do
            described_class.new(
              product_review,
              rating: 4,
              message: "Replace video",
              video_options: {
                create_by_url: new_video_url,
                destroy_by_external_id: existing_video.external_id
              }
            ).update
          end.to change { existing_video.reload.deleted? }.from(false).to(true)
           .and change { product_review.videos.alive.count }.by(0)

          expect(product_review.videos.alive.last.video_file.url).to eq(new_video_url)
        end
      end

      context "when an unpermitted option is provided" do
        it "raises an error" do
          expect do
            described_class.new(
              product_review,
              rating: 4,
              message: "With video",
              video_options: { invalid_option: "invalid" }
            ).update
          end.to raise_error(ArgumentError, "Unpermitted video options: invalid_option")
        end
      end
    end
  end
end
