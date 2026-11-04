# frozen_string_literal: true

require "spec_helper"

describe PostToIndividualPingEndpointWorker do
  before do
    @ok_response = Net::HTTPOK.new("1.1", "200", "OK")
  end

  def post_options(body:, content_type: Mime[:url_encoded_form].to_s)
    {
      body:,
      headers: { "Content-Type" => content_type },
      max_redirects: PostToIndividualPingEndpointWorker::MAX_REDIRECTS,
      allow_unfollowed_redirects: true,
      http_options: { open_timeout: 5, read_timeout: 5 }
    }
  end

  describe "post to individual endpoint" do
    context "when the content_type is application/x-www-form-urlencoded" do
      it "posts to the right endpoint using the right params" do
        expect(SsrfFilter).to receive(:post).with("http://notification.com", post_options(body: "a=1")).and_return(@ok_response)

        expect do
          PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "a" => 1 }, Mime[:url_encoded_form].to_s)
        end.to_not raise_error
      end

      it "posts to the right endpoint and encodes brackets" do
        expect(SsrfFilter).to receive(:post).with(
          "http://notification.com",
          post_options(body: "name%20%255Bfor%20field%255D%20%255B%255B%255D%255D%21%40%23%24%25%5E%26=1&custom_fields%5Bname%20%255Bfor%20field%255D%20%255B%255B%255D%255D%21%40%23%24%25%5E%26%5D=1")
        ).and_return(@ok_response)

        expect do
          PostToIndividualPingEndpointWorker.new.perform(
            "http://notification.com",
            {
              "name [for field] [[]]!@#$%^&" => 1,
              custom_fields: {
                "name [for field] [[]]!@#$%^&" => 1
              }
            },
            Mime[:url_encoded_form].to_s
          )
        end.to_not raise_error
      end
    end

    context "when the content_type is application/json" do
      it "posts to the right endpoint using the right params" do
        expect(SsrfFilter).to receive(:post).with("http://notification.com", post_options(body: { "some [thing]" => 1 }.to_json, content_type: Mime[:json].to_s)).and_return(@ok_response)

        expect do
          PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "some [thing]" => 1 }, Mime[:json].to_s)
        end.to_not raise_error
      end
    end
  end

  describe "signing" do
    before do
      @seller = create(:user)
    end

    it "leaves the delivery unsigned when the seller has not enabled Ping signing" do
      expect(SsrfFilter).to receive(:post).with("http://notification.com", post_options(body: "a=1")).and_return(@ok_response)

      PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "a" => 1 }, Mime[:url_encoded_form].to_s, @seller.id)
    end

    it "signs the exact body it sends when the seller has enabled Ping signing" do
      @seller.enable_ping_signing!

      expect(SsrfFilter).to receive(:post).with("http://notification.com", hash_including(:headers)) do |_url, options|
        expect(options[:headers][PingSignature::HEADER]).to be_present
        expect(
          PingSignature.valid?(
            secret: @seller.ping_signing_secret,
            body: options[:body],
            header: options[:headers][PingSignature::HEADER]
          )
        ).to be(true)
        @ok_response
      end

      PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "a" => 1 }, Mime[:url_encoded_form].to_s, @seller.id)
    end

    it "signs a JSON delivery over the serialized body" do
      @seller.enable_ping_signing!
      params = { "some [thing]" => 1 }

      expect(SsrfFilter).to receive(:post).with("http://notification.com", hash_including(:headers)) do |_url, options|
        expect(options[:body]).to eq(params.to_json)
        expect(
          PingSignature.valid?(
            secret: @seller.ping_signing_secret,
            body: options[:body],
            header: options[:headers][PingSignature::HEADER]
          )
        ).to be(true)
        @ok_response
      end

      PostToIndividualPingEndpointWorker.new.perform("http://notification.com", params, Mime[:json].to_s, @seller.id)
    end

    it "signs a retried delivery again, with a fresh timestamp" do
      @seller.enable_ping_signing!
      headers = []
      allow(SsrfFilter).to receive(:post) do |_url, options|
        headers << options[:headers][PingSignature::HEADER]
        Net::HTTPInternalServerError.new("1.1", "500", "Internal Server Error")
      end

      travel_to(1.minute.from_now.change(usec: 0)) do
        PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "a" => 1 }, Mime[:url_encoded_form].to_s, @seller.id)
      end
      travel_to(10.minutes.from_now.change(usec: 0)) do
        PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "a" => 1, "retry_count" => 1 }, Mime[:url_encoded_form].to_s, @seller.id)
      end

      expect(headers.size).to eq(2)
      expect(headers.uniq.size).to eq(2)
      expect(PingSignature.valid?(secret: @seller.ping_signing_secret, body: "a=1", header: headers.first)).to be(true)
    end

    it "signs with the secret in force at delivery time, not the one from the enqueue" do
      @seller.enable_ping_signing!
      first_secret = @seller.ping_signing_secret
      @seller.enable_ping_signing!

      expect(SsrfFilter).to receive(:post).with("http://notification.com", hash_including(:headers)) do |_url, options|
        header = options[:headers][PingSignature::HEADER]
        expect(PingSignature.valid?(secret: first_secret, body: options[:body], header:)).to be(false)
        expect(PingSignature.valid?(secret: @seller.ping_signing_secret, body: options[:body], header:)).to be(true)
        @ok_response
      end

      PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "a" => 1 }, Mime[:url_encoded_form].to_s, @seller.id)
    end

    it "still delivers the ping, unsigned, when the signing lookup fails" do
      @seller.enable_ping_signing!
      allow(User).to receive(:where).and_raise(StandardError)
      allow(ErrorNotifier).to receive(:notify)
      expect(SsrfFilter).to receive(:post).with("http://notification.com", post_options(body: "a=1")).and_return(@ok_response)

      expect do
        PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "a" => 1 }, Mime[:url_encoded_form].to_s, @seller.id)
      end.to_not raise_error
    end
  end

  it "does not raise when it encounters a retryable internet error" do
    allow(SsrfFilter).to receive(:post).and_raise(SocketError.new("socket error message"))
    messages = []
    allow(Rails.logger).to receive(:info) { |message| messages << message }

    PostToIndividualPingEndpointWorker.new.perform("http://example.com", { "q" => 47 })

    expect(messages).to include("[SocketError] PostToIndividualPingEndpointWorker error content_type=#{Mime[:url_encoded_form]} user_id= retry_count=0")
    expect(PostToIndividualPingEndpointWorker.jobs.size).to eq(1)
  end

  it "re-enqueues itself with backoff on a read timeout" do
    allow(SsrfFilter).to receive(:post).and_raise(Net::ReadTimeout)

    PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "q" => 47 })

    expect(PostToIndividualPingEndpointWorker.jobs.size).to eq(1)
    job = PostToIndividualPingEndpointWorker.jobs.first
    expect(job["args"]).to eq(["http://notification.com", { "q" => 47, "retry_count" => 1 }, Mime[:url_encoded_form].to_s, nil])
    expect(job["at"]).to be_within(5).of(PostToIndividualPingEndpointWorker::BACKOFF_STRATEGY.first.seconds.from_now.to_f)
  end

  it "re-raises a non-internet error" do
    allow(SsrfFilter).to receive(:post).and_raise(StandardError)

    expect do
      PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "q" => 47 })
    end.to raise_error(StandardError)
  end

  it "follows a bounded number of redirects, validated by SsrfFilter" do
    expect(SsrfFilter).to receive(:post).with("http://notification.com", hash_including(max_redirects: 3, allow_unfollowed_redirects: true)).and_return(@ok_response)

    PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "q" => 47 })
  end

  it "follows a trailing-slash redirect and re-sends the payload to the redirect target", :skip_ssrf_stub do
    allow(Resolv).to receive(:getaddresses).with("example.com").and_return(["93.184.216.34"])
    stub_request(:post, "http://example.com/hook/")
      .to_return(status: 308, headers: { "Location" => "http://example.com/hook" })
    delivered = stub_request(:post, "http://example.com/hook")
      .with(body: "a=1", headers: { "Content-Type" => Mime[:url_encoded_form].to_s })
      .to_return(status: 200)

    expect do
      PostToIndividualPingEndpointWorker.new.perform("http://example.com/hook/", { "a" => 1 })
    end.to_not raise_error

    expect(delivered).to have_been_requested
  end

  it "logs and drops the delivery when a redirect points at a private address", :skip_ssrf_stub do
    allow(Resolv).to receive(:getaddresses).with("example.com").and_return(["93.184.216.34"])
    allow(Resolv).to receive(:getaddresses).with("internal.example.net").and_return(["10.0.0.5"])
    stub_request(:post, "http://example.com/hook")
      .to_return(status: 302, headers: { "Location" => "http://internal.example.net/" })
    messages = []
    allow(Rails.logger).to receive(:info) { |message| messages << message }

    expect do
      PostToIndividualPingEndpointWorker.new.perform("http://example.com/hook", { "a" => 1 })
    end.to_not raise_error

    expect(messages).to include("[SsrfFilter::PrivateIPAddress] PostToIndividualPingEndpointWorker error content_type=#{Mime[:url_encoded_form]} user_id=")
    expect(a_request(:post, "http://internal.example.net/")).not_to have_been_made
  end

  it "logs and drops the delivery without raising or retrying when the endpoint still redirects past the limit" do
    redirect_response = Net::HTTPFound.new("1.1", "302", "Found")
    allow(SsrfFilter).to receive(:post).and_return(redirect_response)
    messages = []
    allow(Rails.logger).to receive(:info) { |message| messages << message }

    expect do
      PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "q" => 47 })
    end.to_not raise_error

    expect(messages).to include("PostToIndividualPingEndpointWorker exhausted redirect limit response=302 content_type=#{Mime[:url_encoded_form]} user_id=")
    expect(PostToIndividualPingEndpointWorker.jobs.size).to eq(0)
  end

  it "logs and drops the delivery without raising when the URL resolves to a private address at connect time" do
    allow(SsrfFilter).to receive(:post).and_raise(SsrfFilter::PrivateIPAddress.new("Hostname 'notification.com' has no public ip addresses"))
    messages = []
    allow(Rails.logger).to receive(:info) { |message| messages << message }

    expect do
      PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "q" => 47 })
    end.to_not raise_error

    expect(messages).to include("[SsrfFilter::PrivateIPAddress] PostToIndividualPingEndpointWorker error content_type=#{Mime[:url_encoded_form]} user_id=")
    expect(PostToIndividualPingEndpointWorker.jobs.size).to eq(0)
  end

  it "sends URL userinfo as basic auth" do
    request_proc = nil
    expect(SsrfFilter).to receive(:post).with("http://user:secret@notification.com/hook", hash_including(:request_proc)) do |_url, options|
      request_proc = options[:request_proc]
      @ok_response
    end

    PostToIndividualPingEndpointWorker.new.perform("http://user:secret@notification.com/hook", { "a" => 1 })

    request = Net::HTTP::Post.new(URI("http://notification.com/hook"))
    request_proc.call(request)
    expect(request["authorization"]).to eq("Basic #{Base64.strict_encode64("user:secret")}")
  end

  it "re-enqueues itself with backoff when the endpoint hostname does not resolve" do
    allow(SsrfFilter).to receive(:post).and_raise(SsrfFilter::UnresolvedHostname.new("Could not resolve hostname 'notification.com'"))

    PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "q" => 47 })

    expect(PostToIndividualPingEndpointWorker.jobs.size).to eq(1)
    job = PostToIndividualPingEndpointWorker.jobs.first
    expect(job["args"]).to eq(["http://notification.com", { "q" => 47, "retry_count" => 1 }, Mime[:url_encoded_form].to_s, nil])
    expect(job["at"]).to be_within(5).of(PostToIndividualPingEndpointWorker::BACKOFF_STRATEGY.first.seconds.from_now.to_f)
  end

  it "retries an unresolved hostname the right number of times and does not raise", :sidekiq_inline do
    expect(SsrfFilter).to receive(:post).exactly(4).times.with("http://notification.com", kind_of(Hash)).and_raise(SsrfFilter::UnresolvedHostname.new("Could not resolve hostname 'notification.com'"))

    PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "b" => 3 })
  end

  it "retries 50x status codes the right number of times and does not raise", :sidekiq_inline do
    error_response = Net::HTTPInternalServerError.new("1.1", "500", "Internal Server Error")
    expect(SsrfFilter).to receive(:post).exactly(4).times.with("http://notification.com", kind_of(Hash)).and_return(error_response)

    PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "b" => 3 })
  end

  it "does not retry other status codes", :sidekiq_inline do
    error_response = Net::HTTPExpectationFailed.new("1.1", "417", "Expectation Failed")
    expect(SsrfFilter).to receive(:post).exactly(1).times.with("http://notification.com", kind_of(Hash)).and_return(error_response)

    PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "c" => 17 })
  end

  describe "logging" do
    it "does not log the endpoint URL or payload" do
      expect(SsrfFilter).to receive(:post).with("https://notification.com", post_options(body: "a=1")).and_return(@ok_response)
      messages = []
      allow(Rails.logger).to receive(:info) { |message| messages << message }

      PostToIndividualPingEndpointWorker.new.perform("https://notification.com", { "a" => 1 })

      expect(messages.join("\n")).not_to include("https://notification.com", '"a" => 1')
    end

    it "does not log license keys or webhook credentials" do
      endpoint = "https://notification.com/webhook?token=endpoint-secret"
      payload = { "license_key" => "license-secret", "email" => "buyer@example.com" }
      expect(SsrfFilter).to receive(:post).with(endpoint, post_options(body: "license_key=license-secret&email=buyer%40example.com")).and_return(@ok_response)
      messages = []
      allow(Rails.logger).to receive(:info) { |message| messages << message }

      PostToIndividualPingEndpointWorker.new.perform(endpoint, payload)

      logged = messages.join("\n")
      expect(logged).not_to include(endpoint, "endpoint-secret", "license-secret", "buyer@example.com")
    end
  end

  describe "delivery records" do
    let(:seller) { create(:user) }
    let(:purchase) { create(:free_purchase, seller:, link: create(:product, user: seller)) }
    let(:ping) { { "purchase_id" => purchase.id, "subscription_id" => nil, "resource_name" => ResourceSubscription::SALE_RESOURCE_NAME } }

    it "records the attempt with the endpoint's response for that sale" do
      expect(SsrfFilter).to receive(:post).and_return(@ok_response)

      PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "a" => 1 }, Mime[:url_encoded_form].to_s, seller.id, ping)

      delivery = seller.ping_deliveries.sole
      expect(delivery).to have_attributes(
        purchase_id: purchase.id,
        resource_name: ResourceSubscription::SALE_RESOURCE_NAME,
        post_url: "http://notification.com",
        attempt: 1,
        response_code: 200,
        error_class: nil,
        succeeded: true
      )
    end

    it "records a rejection the worker does not retry" do
      allow(SsrfFilter).to receive(:post).and_return(Net::HTTPExpectationFailed.new("1.1", "417", "Expectation Failed"))

      PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "a" => 1 }, Mime[:url_encoded_form].to_s, seller.id, ping)

      expect(seller.ping_deliveries.sole).to have_attributes(response_code: 417, error_class: nil, succeeded: false)
    end

    it "records the error class when the connection never completed" do
      allow(SsrfFilter).to receive(:post).and_raise(SocketError.new("socket error message"))

      PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "a" => 1 }, Mime[:url_encoded_form].to_s, seller.id, ping)

      expect(seller.ping_deliveries.sole).to have_attributes(response_code: nil, error_class: "SocketError", succeeded: false)
    end

    it "numbers each retry attempt" do
      allow(SsrfFilter).to receive(:post).and_return(Net::HTTPInternalServerError.new("1.1", "500", "Internal Server Error"))

      PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "a" => 1, "retry_count" => 2 }, Mime[:url_encoded_form].to_s, seller.id, ping)

      expect(seller.ping_deliveries.sole.attempt).to eq(3)
    end

    it "carries the sale context into the retry it enqueues" do
      allow(SsrfFilter).to receive(:post).and_raise(Net::ReadTimeout)

      PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "a" => 1 }, Mime[:url_encoded_form].to_s, seller.id, ping)

      expect(PostToIndividualPingEndpointWorker.jobs.sole["args"].last).to eq(ping)
    end

    it "records nothing for a job enqueued before the ping context argument existed" do
      expect(SsrfFilter).to receive(:post).and_return(@ok_response)

      PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "a" => 1 }, Mime[:url_encoded_form].to_s, seller.id)

      expect(PingDelivery.count).to eq(0)
    end

    it "delivers the ping even when the attempt cannot be recorded" do
      allow(SsrfFilter).to receive(:post).and_return(@ok_response)
      allow(PingDelivery).to receive(:create!).and_raise(ActiveRecord::StatementInvalid.new("gone away"))

      expect do
        PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "a" => 1 }, Mime[:url_encoded_form].to_s, seller.id, ping)
      end.to_not raise_error
    end
  end
end
