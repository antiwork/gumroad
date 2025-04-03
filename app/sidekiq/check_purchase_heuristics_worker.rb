# frozen_string_literal: true

class CheckPurchaseHeuristicsWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(purchase_id)
    return unless Rails.env.production?

    sqs = Aws::SQS::Client.new
    queue_url = sqs.get_queue_url(queue_name: "risk_queue").queue_url
    sqs.send_message(queue_url:, message_body: { "type" => "purchase", "id" => purchase_id }.to_s)
  end
end
