# frozen_string_literal: true

class ContentModeration::ModerateProfileJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 3

  def perform(user_id)
    user = User.alive.find_by(id: user_id)
    return if user.nil?

    ContentModeration::ModerateRecordService.new(user, :profile).perform
  end
end
