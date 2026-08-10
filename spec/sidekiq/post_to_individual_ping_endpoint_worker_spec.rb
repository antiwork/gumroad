# frozen_string_literal: true

require "spec_helper"

describe PostToIndividualPingEndpointWorker do
  before do
    @http_double = double
    allow(@http_double).to receive(:success?).and_return(true)
    allow(@http_double).to receive(:code).and_return(200)
  end

  describe "post to individual endpoint" do
    context "when the content_type is application/x-www-form-urlencoded" do
      it "posts to the right endpoint using the right params" do
        expect(HTTParty).to receive(:post).with("http://notification.com", timeout: 5, body: { "a" => 1 }, headers: { "Content-Type" => "application/x-www-form-urlencoded" }, no_follow: true).and_return(@http_double)

        expect do
          PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "a" => 1 }, Mime[:url_encoded_form].to_s)
        end.to_not raise_error
      end

      it "posts to the right endpoint and encodes brackets" do
        expect(HTTParty).to receive(:post).with(
          "http://notification.com",
          timeout: 5,
          body: {
            "name %5Bfor field%5D %5B%5B%5D%5D!@\#$%^&" => 1,
            "custom_fields" => {
              "name %5Bfor field%5D %5B%5B%5D%5D!@\#$%^&" => 1
            }
          },
          headers: { "Content-Type" => "application/x-www-form-urlencoded" },
          no_follow: true
        ).and_return(@http_double)

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
        expect(HTTParty).to receive(:post).with("http://notification.com", timeout: 5, body: { "some [thing]" => 1 }.to_json, headers: { "Content-Type" => "application/json" }, no_follow: true).and_return(@http_double)

        expect do
          PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "some [thing]" => 1 }, Mime[:json].to_s)
        end.to_not raise_error
      end
    end
  end

  it "does not raise when it encounters an internet error" do
    allow(HTTParty).to receive(:post).and_raise(SocketError.new("socket error message"))
    messages = []
    allow(Rails.logger).to receive(:info) { |message| messages << message }
    expect(HTTParty).to receive(:post).exactly(1).times

    PostToIndividualPingEndpointWorker.new.perform("http://example.com", { "q" => 47 })

    expect(messages).to include("[SocketError] PostToIndividualPingEndpointWorker error content_type=#{Mime[:url_encoded_form]} user_id=")
  end

  it "re-raises a non-internet error" do
    allow(HTTParty).to receive(:post).and_raise(StandardError)

    expect do
      PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "q" => 47 })
    end.to raise_error(StandardError)
  end

  it "does not follow redirects" do
    expect(HTTParty).to receive(:post).with("http://notification.com", hash_including(no_follow: true)).and_return(@http_double)

    PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "q" => 47 })
  end

  it "logs and drops the delivery without raising or retrying when the endpoint responds with a redirect" do
    redirect_response = Net::HTTPFound.new("1.1", "302", "Found")
    allow(HTTParty).to receive(:post).and_raise(HTTParty::RedirectionTooDeep.new(redirect_response))
    messages = []
    allow(Rails.logger).to receive(:info) { |message| messages << message }

    expect do
      PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "q" => 47 })
    end.to_not raise_error

    expect(messages).to include("PostToIndividualPingEndpointWorker refused redirect response=302 content_type=#{Mime[:url_encoded_form]} user_id=")
    expect(PostToIndividualPingEndpointWorker.jobs.size).to eq(0)
  end

  it "re-validates the post_url against the SSRF guard before connecting, and skips the request if it now resolves to a private address" do
    allow(ResourceSubscription).to receive(:valid_post_url?).with("http://notification.com").and_return(false)
    expect(HTTParty).not_to receive(:post)

    PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "q" => 47 })
  end

  it "retries 50x status codes the right number of times and does not raise", :sidekiq_inline do
    allow(@http_double).to receive(:success?).and_return(false)
    allow(@http_double).to receive(:code).and_return(500)
    expect(HTTParty).to receive(:post).exactly(4).times.with("http://notification.com", kind_of(Hash)).and_return(@http_double)

    PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "b" => 3 })
  end

  it "does not retry other status codes", :sidekiq_inline do
    allow(@http_double).to receive(:success?).and_return(false)
    allow(@http_double).to receive(:code).and_return(417)
    expect(HTTParty).to receive(:post).exactly(1).times.with("http://notification.com", kind_of(Hash)).and_return(@http_double)

    PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "c" => 17 })
  end

  describe "logging" do
    it "does not log the endpoint URL or payload" do
      expect(HTTParty).to receive(:post).with("https://notification.com", timeout: 5, body: { "a" => 1 }, headers: { "Content-Type" => Mime[:url_encoded_form] }, no_follow: true).and_return(@http_double)
      messages = []
      allow(Rails.logger).to receive(:info) { |message| messages << message }

      PostToIndividualPingEndpointWorker.new.perform("https://notification.com", { "a" => 1 })

      expect(messages.join("\n")).not_to include("https://notification.com", '"a" => 1')
    end

    it "does not log license keys or webhook credentials" do
      endpoint = "https://notification.com/webhook?token=endpoint-secret"
      payload = { "license_key" => "license-secret", "email" => "buyer@example.com" }
      expect(HTTParty).to receive(:post).with(endpoint, timeout: 5, body: payload, headers: { "Content-Type" => Mime[:url_encoded_form] }, no_follow: true).and_return(@http_double)
      messages = []
      allow(Rails.logger).to receive(:info) { |message| messages << message }

      PostToIndividualPingEndpointWorker.new.perform(endpoint, payload)

      logged = messages.join("\n")
      expect(logged).not_to include(endpoint, "endpoint-secret", "license-secret", "buyer@example.com")
    end
  end
end
