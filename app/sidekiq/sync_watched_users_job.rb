# frozen_string_literal: true

class SyncWatchedUsersJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  def perform
    WatchedUser.alive.find_each do |watched_user|
      watched_user.sync!
    rescue => e
      ErrorNotifier.notify(e, context: { watched_user_id: watched_user.id })
    end
  end
end
