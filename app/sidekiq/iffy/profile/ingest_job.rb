# frozen_string_literal: true

class Iffy::Profile::IngestJob
  include Sidekiq::Job
  sidekiq_options queue: :long, retry: 3

  def perform(user_id)
    user = User.find(user_id)

    Iffy::Profile::IngestService.new(user).perform
  end
end
