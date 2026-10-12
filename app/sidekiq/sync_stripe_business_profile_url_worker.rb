# frozen_string_literal: true

# Drains jobs enqueued under the old class name before the rename deployed.
class SyncStripeBusinessProfileUrlWorker
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  def perform(user_id, old_username)
    SyncStripeBusinessProfileUrlJob.new.perform(user_id, old_username)
  end
end
