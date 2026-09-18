# frozen_string_literal: true

class EnqueueMarketingXReconnectEmailJob
  include Sidekiq::Job
  # This job must stay non-unique: a conflict with an in-flight delivery needs its own
  # durable retry, even if that delivery has already made its final eligibility check.
  sidekiq_options queue: :low

  def perform(seller_id)
    SendMarketingXReconnectEmailJob.set(on_conflict: { client: :raise }).perform_async(seller_id)
  end
end
