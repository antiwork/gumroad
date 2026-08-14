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

  it "does not raise when it encounters an internet error" do
    allow(SsrfFilter).to receive(:post).and_raise(SocketError.new("socket error message"))
    messages = []
    allow(Rails.logger).to receive(:info) { |message| messages << message }
    expect(SsrfFilter).to receive(:post).exactly(1).times

    PostToIndividualPingEndpointWorker.new.perform("http://example.com", { "q" => 47 })

    expect(messages).to include("[SocketError] PostToIndividualPingEndpointWorker error content_type=#{Mime[:url_encoded_form]} user_id=")
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
end
