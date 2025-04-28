# frozen_string_literal: true

class ProductReviewVideoPresenter
  attr_reader :video

  def initialize(video)
    @video = video
  end

  def props(pundit_user:)
    {
      id: video.external_id,
      approval_status: video.approval_status,
      thumbnail_url: video.video_file.thumbnail_url,
      can_approve: Pundit.policy!(pundit_user, video).approve?,
      can_reject: Pundit.policy!(pundit_user, video).reject?,
    }
  end
end
