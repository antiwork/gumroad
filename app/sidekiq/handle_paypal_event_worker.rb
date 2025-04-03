# frozen_string_literal: true

class HandlePaypalEventWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(paypal_event)
    PaypalEventHandler.new(paypal_event).handle_paypal_event
  end
end
