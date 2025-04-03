# frozen_string_literal: true

class ScoreProductWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(product_id)
    return unless Rails.env.production?
    sqs = Aws::SQS::Client.new
    queue_url = sqs.get_queue_url(queue_name: "risk_queue").queue_url
    sqs.send_message(queue_url:, message_body: { "type" => "product", "id" => product_id }.to_s)
  end
end
