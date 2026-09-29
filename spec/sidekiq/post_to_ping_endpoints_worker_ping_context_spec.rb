# frozen_string_literal: true

require "spec_helper"

describe PostToPingEndpointsWorker, "ping delivery context" do
  let(:seller) { create(:user, notification_endpoint: "https://example.com/hook") }
  let(:purchase) { create(:free_purchase, link: create(:product, user: seller), seller:) }

  before do
    allow(Purchase).to receive(:find).with(purchase.id).and_return(purchase)
    allow(purchase).to receive(:payload_for_ping_notification).and_return({ sale_id: "x" })
  end

  it "enqueues the four-argument job while :record_ping_deliveries is off" do
    described_class.new.perform(purchase.id, nil)

    expect(PostToIndividualPingEndpointWorker.jobs.sole["args"].size).to eq(4)
  end

  it "adds the sale context once :record_ping_deliveries is on" do
    Feature.activate(:record_ping_deliveries)

    described_class.new.perform(purchase.id, nil)

    expect(PostToIndividualPingEndpointWorker.jobs.sole["args"].last).to eq(
      "resource_name" => ResourceSubscription::SALE_RESOURCE_NAME,
      "purchase_id" => purchase.id,
      "subscription_id" => nil
    )
  end
end
