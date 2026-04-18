# frozen_string_literal: true

class ContentModeration::ModeratePostJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 3

  def perform(post_id)
    post = Installment.alive.find_by(id: post_id)
    return if post.nil?

    ContentModeration::ModerateRecordService.new(post, :post).perform
  end
end
