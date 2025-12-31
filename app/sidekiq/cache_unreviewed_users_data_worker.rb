# frozen_string_literal: true

class CacheUnreviewedUsersDataWorker
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :default

  def perform
    Admin::UnreviewedUsersService.cache_users_data!
  end
end
