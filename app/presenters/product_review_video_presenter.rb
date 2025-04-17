# frozen_string_literal: true

class ProductReviewVideoPresenter
  attr_reader :video

  def initialize(video)
    @video = video
  end

  def props
    {
      id: video.external_id,
      approval_status: video.approval_status,
      thumbnail_url: video.video_file.thumbnail_url,
    }
  end
end
