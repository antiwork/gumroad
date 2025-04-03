# frozen_string_literal: true

class HandleStripeEventWorker
  include Sidekiq::Job
  sidekiq_options retry: 10, queue: :default

  def perform(params)
    StripeEventHandler.new(params).handle_stripe_event
  end
end
