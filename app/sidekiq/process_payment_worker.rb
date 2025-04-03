# frozen_string_literal: true

class ProcessPaymentWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  def perform(payment_id)
    payment = Payment.find(payment_id)

    return unless payment.processing?

    PayoutProcessorType.get(payment.processor).process_payments([payment])
  end
end
