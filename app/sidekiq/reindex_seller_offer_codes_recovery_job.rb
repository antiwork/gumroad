# frozen_string_literal: true

class ReindexSellerOfferCodesRecoveryJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 10

  sidekiq_retries_exhausted do |message, _error|
    perform_in(1.hour, message.fetch("args").first)
  end

  def perform(seller_id)
    ReindexSellerOfferCodesJob.new.perform(seller_id)
  end
end
