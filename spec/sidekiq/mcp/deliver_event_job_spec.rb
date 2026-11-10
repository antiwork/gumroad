# frozen_string_literal: true

require "spec_helper"

describe Mcp::DeliverEventJob do
  let(:callback_url) { "https://example.com/hooks/mcp" }
  let(:subscription) { create(:mcp_event_subscription, callback_url:) }
  let(:event) do
    {
      "eventId" => "evt_sale_123",
      "name" => "sale.created",
      "timestamp" => "2026-11-10T12:00:00Z",
      "data" => { "sale_id" => "123" },
      "cursor" => nil
    }
  end

  before do
    allow(Resolv).to receive(:getaddresses).with("example.com").and_return(["93.184.216.34"])
    create("doorkeeper/access_token", application: subscription.oauth_application, resource_owner_id: subscription.user_id, scopes: "view_sales")
  end

  def perform(attempt = 0)
    described_class.new.perform(subscription.id, event, attempt)
  end

  it "sends nothing and deletes the subscription once the connection holds no token with the scope" do
    Doorkeeper::AccessToken.where(resource_owner_id: subscription.user_id).find_each(&:revoke)
    create("doorkeeper/access_token", application: subscription.oauth_application, resource_owner_id: subscription.user_id, scopes: "view_public")
    create("doorkeeper/access_token", application: create(:oauth_application), resource_owner_id: subscription.user_id, scopes: "view_sales")
    allow(Rails.logger).to receive(:info)

    perform

    expect(a_request(:post, callback_url)).not_to have_been_made
    expect(McpEventSubscription.exists?(subscription.id)).to be(false)
    expect(described_class.jobs.size).to eq(0)
    expect(Rails.logger).to have_received(:info).with("mcp_event_delivery subscription_id=#{subscription.id} event=sale.created attempt=1 outcome=access_revoked")
  end

  it "stops delivering on a team member's token once the membership ends" do
    Doorkeeper::AccessToken.where(resource_owner_id: subscription.user_id).find_each(&:revoke)
    membership = create(:team_membership, seller: subscription.user)
    create("doorkeeper/access_token", application: subscription.oauth_application, resource_owner_id: subscription.user_id, scopes: "view_sales", team_membership_id: membership.id)
    stub_request(:post, callback_url).to_return(status: 204)

    perform
    membership.update_columns(deleted_at: Time.current)
    perform

    expect(a_request(:post, callback_url)).to have_been_made.once
    expect(McpEventSubscription.exists?(subscription.id)).to be(false)
  end

  it "delivers to a connection whose token holds the account scope" do
    Doorkeeper::AccessToken.where(resource_owner_id: subscription.user_id).find_each(&:revoke)
    create("doorkeeper/access_token", application: subscription.oauth_application, resource_owner_id: subscription.user_id, scopes: "account")
    stub_request(:post, callback_url).to_return(status: 204)

    perform

    expect(a_request(:post, callback_url)).to have_been_made.once
  end

  it "delivers the event under its own id, logs the attempt, and schedules nothing after a 2xx" do
    delivered = stub_request(:post, callback_url)
      .with(body: event.to_json, headers: { "Webhook-Id" => "evt_sale_123", "X-Mcp-Subscription-Id" => subscription.public_id })
      .to_return(status: 204)
    allow(Rails.logger).to receive(:info)

    perform

    expect(delivered).to have_been_requested.once
    expect(described_class.jobs.size).to eq(0)
    expect(Rails.logger).to have_received(:info).with("mcp_event_delivery subscription_id=#{subscription.id} event=sale.created attempt=1 outcome=http_204")
  end

  it "schedules the next attempt later each time the endpoint fails", :freeze_time do
    stub_request(:post, callback_url).to_return(status: 500)

    [30.seconds, 2.minutes, 8.minutes].each_with_index do |delay, attempt|
      perform(attempt)

      job = described_class.jobs.last
      expect(job["args"]).to eq([subscription.id, event, attempt + 1])
      expect(Time.zone.at(job["at"])).to eq(delay.from_now)
    end
    expect(described_class.jobs.size).to eq(3)
  end

  it "drops the event when the last attempt fails" do
    stub_request(:post, callback_url).to_return(status: 500)

    perform(3)

    expect(described_class.jobs.size).to eq(0)
  end

  it "signs each attempt again, under the same message id and with the secret of that moment", :freeze_time do
    sent = []
    # In the response, which runs once for each request. A `with` block runs more often than that.
    stub_request(:post, callback_url).to_return(->(request) { sent << request; { status: 500 } })
    rotated_secret = "whsec_#{Base64.strict_encode64(SecureRandom.bytes(32))}"

    perform(0)
    travel 30.seconds
    subscription.update!(secret: rotated_secret)
    perform(1)

    expect(sent.map { _1.headers["Webhook-Id"] }).to eq(%w[evt_sale_123 evt_sale_123])
    first_signed_at, second_signed_at = sent.map { _1.headers["Webhook-Timestamp"].to_i }
    expect(second_signed_at - first_signed_at).to eq(30)
    expect(sent.last.headers["Webhook-Signature"]).to eq(
      Mcp::EventSignature.headers(secret: rotated_secret, message_id: "evt_sale_123", body: event.to_json, timestamp: second_signed_at)["webhook-signature"]
    )
  end

  it "does not send the event again after a 410 or a 413" do
    [410, 413].each do |status|
      stub_request(:post, callback_url).to_return(status:)

      perform
    end

    expect(a_request(:post, callback_url)).to have_been_made.twice
    expect(described_class.jobs.size).to eq(0)
  end

  it "schedules another attempt when the endpoint does not answer in time, and logs the reason" do
    stub_request(:post, callback_url).to_timeout
    allow(Rails.logger).to receive(:info)

    expect { perform }.not_to raise_error

    expect(described_class.jobs.size).to eq(1)
    expect(Rails.logger).to have_received(:info).with("mcp_event_delivery subscription_id=#{subscription.id} event=sale.created attempt=1 outcome=timeout")
  end

  it "drops the event when the callback URL resolves to a private address" do
    allow(Resolv).to receive(:getaddresses).with("example.com").and_return(["10.0.0.5"])

    expect { perform }.not_to raise_error

    expect(a_request(:post, callback_url)).not_to have_been_made
    expect(described_class.jobs.size).to eq(0)
  end

  it "sends nothing for a subscription whose lease ended or that is gone" do
    subscription.update_columns(expires_at: 1.minute.ago)
    perform

    subscription.delete
    perform

    expect(a_request(:post, callback_url)).not_to have_been_made
    expect(described_class.jobs.size).to eq(0)
  end
end
