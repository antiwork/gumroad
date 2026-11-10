# frozen_string_literal: true

require "spec_helper"

describe Mcp::EventWebhook do
  let(:callback_url) { "https://example.com/hooks/mcp" }

  before { allow(Resolv).to receive(:getaddresses).with("example.com").and_return(["93.184.216.34"]) }

  # Stubs the endpoint and keeps the request it was sent.
  def stub_callback(response)
    stub_request(:post, callback_url).with { |request| @sent = request }.to_return(response)
  end

  def echo_with(status)
    ->(request) { { status:, body: { challenge: JSON.parse(request.body)["challenge"] }.to_json } }
  end

  def expect_signed_with_the_subscription_secret(request)
    signed = Mcp::EventSignature.headers(
      secret: subscription.secret,
      message_id: request.headers["Webhook-Id"],
      body: request.body,
      timestamp: request.headers["Webhook-Timestamp"].to_i
    )
    expect(request.headers["Webhook-Signature"]).to eq(signed["webhook-signature"])
  end

  def expect_callback_error(reason, retryable: true, &block)
    expect(&block).to raise_error(described_class::CallbackError) do |error|
      expect(error.reason).to eq(reason)
      expect(error.retryable?).to eq(retryable)
    end
  end

  describe ".post" do
    let(:subscription) { build_stubbed(:mcp_event_subscription, callback_url:, key_digest: SecureRandom.hex(32)) }

    def post
      described_class.post(subscription, message_id: "evt_sale_123", payload: { name: "sale.created" })
    end

    it "sends the signed JSON payload to the callback URL and returns the status and the answer", :freeze_time do
      stub_callback(status: 200, body: "accepted")

      response = post

      expect(response.status).to eq(200)
      expect(response.body).to eq("accepted")
      expect(response).to be_success
      expect(@sent.body).to eq('{"name":"sale.created"}')
      expect(@sent.headers).to include(
        "Content-Type" => "application/json",
        "Accept-Encoding" => "identity",
        "X-Mcp-Subscription-Id" => subscription.public_id,
        "Webhook-Id" => "evt_sale_123",
        "Webhook-Timestamp" => Time.current.to_i.to_s
      )
      expect_signed_with_the_subscription_secret(@sent)
    end

    it "returns a redirect as it is and sends nothing to its target" do
      stub_callback(status: 302, headers: { "Location" => "https://example.org/elsewhere" })

      response = post

      expect(response.status).to eq(302)
      expect(response).not_to be_success
      expect(a_request(:post, "https://example.org/elsewhere")).not_to have_been_made
    end

    it "keeps the status and drops an answer over the size limit" do
      stub_callback(status: 200, body: "a" * (described_class::MAX_RESPONSE_BYTES + 1))

      response = post

      expect(response.status).to eq(200)
      expect(response.body).to eq("")
    end

    it "names the reason when the endpoint gives no answer, and lets the caller try again" do
      {
        Net::OpenTimeout => "timeout",
        OpenSSL::SSL::SSLError => "tls_error",
        Errno::ECONNREFUSED => "connection_refused",
        Errno::EPIPE => "connection_refused",
        IOError => "connection_refused"
      }.each do |error, reason|
        stub_request(:post, callback_url).to_raise(error)

        expect_callback_error(reason) { post }
      end
    end

    it "stops a request that takes longer than the total time limit" do
      stub_const("Mcp::EventWebhook::TOTAL_TIMEOUT_SECONDS", 0.05)
      stub_request(:post, callback_url).to_return(->(_request) { sleep 0.5; { status: 200 } })

      expect_callback_error("timeout") { post }
    end

    it "sends nothing to a callback URL that resolves to a private address, and rules out another try" do
      allow(Resolv).to receive(:getaddresses).with("example.com").and_return(["10.0.0.5"])

      expect_callback_error("connection_refused", retryable: false) { post }
      expect(a_request(:post, callback_url)).not_to have_been_made
    end

    it "sends nothing to a callback URL that is not https, and rules out another try" do
      allow(subscription).to receive(:callback_url).and_return("http://example.com/hooks/mcp")

      expect_callback_error("connection_refused", retryable: false) { post }
      expect(a_request(:post, "http://example.com/hooks/mcp")).not_to have_been_made
    end
  end

  describe ".verify!" do
    # Not stored: a first subscribe verifies the endpoint before it keeps anything.
    let(:subscription) { build(:mcp_event_subscription, callback_url:) }

    it "passes when the endpoint echoes the signed challenge" do
      stub_callback(echo_with(200))

      expect { described_class.verify!(subscription) }.not_to raise_error

      expect(JSON.parse(@sent.body)).to match("type" => "verification", "challenge" => a_string_matching(/\A[\w-]{43}\z/))
      expect(@sent.headers["Webhook-Id"]).to start_with("msg_verification_")
      expect(@sent.headers["X-Mcp-Subscription-Id"]).to eq(subscription.public_id)
      expect_signed_with_the_subscription_secret(@sent)
    end

    it "fails when the endpoint does not echo the challenge in a 2xx answer of its own" do
      [
        { status: 200, body: { challenge: "another" }.to_json },
        { status: 200, body: { challenge: 1 }.to_json },
        { status: 200, body: "accepted" },
        { status: 200, body: "[]" },
        { status: 204 },
        echo_with(500),
        # A mirror: the request body, sent back as it came.
        ->(request) { { status: 200, body: request.body } }
      ].each do |response|
        stub_callback(response)

        expect_callback_error("challenge_failed") { described_class.verify!(subscription) }
      end
    end

    it "names the reason when the endpoint gives no answer" do
      stub_request(:post, callback_url).to_timeout

      expect_callback_error("timeout") { described_class.verify!(subscription) }
    end

    it "refuses a subscription that is not valid before it sends anything" do
      subscription.secret = "not a secret"

      expect { described_class.verify!(subscription) }.to raise_error(ActiveRecord::RecordInvalid, /Secret must be whsec_/)
      expect(a_request(:post, callback_url)).not_to have_been_made
    end
  end
end
