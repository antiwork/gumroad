# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProductReviewVideoPresenter do
  let(:video) { create(:product_review_video, :approved) }

  describe "#props" do
    it "returns the correct props" do
      presenter = described_class.new(video)

      expect(presenter.props).to eq(
        id: video.external_id,
        approval_status: video.approval_status,
        thumbnail_url: video.video_file.thumbnail_url
      )
    end
  end
end
