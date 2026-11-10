# frozen_string_literal: true

require "spec_helper"

describe PostToPingEndpointsWorker, "MCP events" do
  let(:seller) { create(:user, notification_endpoint: "https://example.com/hook") }
  let(:purchase) { create(:free_purchase, link: create(:product, user: seller), seller:) }

  before do
    allow(Purchase).to receive(:find).with(purchase.id).and_return(purchase)
    allow(purchase).to receive(:payload_for_ping_notification).and_return({ sale_id: "x" })
  end

  it "publishes the sale to MCP subscribers along with the pings" do
    expect(Mcp::Events).to receive(:publish_sale).with(purchase)

    described_class.new.perform(purchase.id, nil)

    expect(PostToIndividualPingEndpointWorker.jobs.size).to eq(1)
  end

  it "publishes nothing for a ping about anything but a sale" do
    expect(Mcp::Events).not_to receive(:publish_sale)

    described_class.new.perform(purchase.id, nil, ResourceSubscription::REFUNDED_RESOURCE_NAME)
  end

  it "publishes nothing when queuing a ping fails, so the retry publishes once" do
    allow(PostToIndividualPingEndpointWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError)
    expect(Mcp::Events).not_to receive(:publish_sale)

    expect { described_class.new.perform(purchase.id, nil) }.to raise_error(Redis::CannotConnectError)
  end

  it "publishes the sale of a seller with no ping endpoint" do
    seller.update!(notification_endpoint: nil)
    expect(Mcp::Events).to receive(:publish_sale).with(purchase)

    described_class.new.perform(purchase.id, nil)

    expect(PostToIndividualPingEndpointWorker.jobs.size).to eq(0)
  end

  it "still sends the pings, and reports the error, when publishing fails" do
    error = StandardError.new("publish failed")
    allow(Mcp::Events).to receive(:publish_sale).and_raise(error)
    expect(ErrorNotifier).to receive(:notify).with(error)

    described_class.new.perform(purchase.id, nil)

    expect(PostToIndividualPingEndpointWorker.jobs.size).to eq(1)
  end
end
