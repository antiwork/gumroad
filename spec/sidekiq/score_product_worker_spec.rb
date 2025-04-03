# frozen_string_literal: true

describe ScoreProductWorker, :vcr do
  describe "#perform" do
    before do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
    end

    it "sends message to SQS risk queue" do
      sqs = Aws::SQS::Client.new
      queue_url = sqs.get_queue_url(queue_name: "risk_queue").queue_url
      expect_any_instance_of(Aws::SQS::Client).to receive(:send_message).with({ queue_url:, message_body: { "type" => "product", "id" => 123 }.to_s })
      ScoreProductWorker.new.perform(123)
    end
  end
end
