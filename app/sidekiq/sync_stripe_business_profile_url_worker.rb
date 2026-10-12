# frozen_string_literal: true

class SyncStripeBusinessProfileUrlWorker
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  def perform(user_id, _old_username = nil)
    SyncStripeBusinessProfileUrlJob.perform_async(user_id)
  end
end
