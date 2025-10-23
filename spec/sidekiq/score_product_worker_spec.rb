# frozen_string_literal: true

describe ScoreProductWorker, :vcr do
  describe "#perform" do
    before do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
    end

    it "sends message to SQS risk queue" do
      sqs_client = instance_double(Aws::SQS::Client)
      queue_url = "https://sqs.us-east-1.amazonaws.com/123456789012/risk_queue"
      queue_url_response = instance_double(Aws::SQS::Types::GetQueueUrlResult, queue_url:)

      allow(Aws::SQS::Client).to receive(:new).and_return(sqs_client)
      allow(sqs_client).to receive(:get_queue_url).with(queue_name: "risk_queue").and_return(queue_url_response)
      expect(sqs_client).to receive(:send_message).with({ queue_url:, message_body: { "type" => "product", "id" => 123 }.to_s })

      ScoreProductWorker.new.perform(123)
    end
  end
end
