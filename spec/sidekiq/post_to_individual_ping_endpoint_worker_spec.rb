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
        expect(HTTParty).to receive(:post).with("http://notification.com", timeout: 5, body: { "a" => 1 }, headers: { "Content-Type" => "application/x-www-form-urlencoded" }).and_return(@http_double)

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
          headers: { "Content-Type" => "application/x-www-form-urlencoded" }
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
        expect(HTTParty).to receive(:post).with("http://notification.com", timeout: 5, body: { "some [thing]" => 1 }.to_json, headers: { "Content-Type" => "application/json" }).and_return(@http_double)

        expect do
          PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "some [thing]" => 1 }, Mime[:json].to_s)
        end.to_not raise_error
      end
    end
  end

  it "does not raise when it encounters an internet error" do
    allow(HTTParty).to receive(:post).and_raise(SocketError.new("socket error message"))
    expect(Rails.logger).to receive(:info).with("[SocketError] PostToIndividualPingEndpointWorker error=\"socket error message\" url=http://example.com content_type=#{Mime[:url_encoded_form]} params={\"q\" => 47}")
    expect(HTTParty).to receive(:post).exactly(1).times

    PostToIndividualPingEndpointWorker.new.perform("http://example.com", { "q" => 47 })
  end

  it "re-raises a non-internet error" do
    allow(HTTParty).to receive(:post).and_raise(StandardError)

    expect do
      PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "q" => 47 })
    end.to raise_error(StandardError)
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
    it "logs url, response code and params" do
      expect(HTTParty).to receive(:post).with("https://notification.com", timeout: 5, body: { "a" => 1 }, headers: { "Content-Type" => Mime[:url_encoded_form] }).and_return(@http_double)
      expect(Rails.logger).to receive(:info).with("PostToIndividualPingEndpointWorker response=200 url=https://notification.com content_type=#{Mime[:url_encoded_form]} params={\"a\" => 1}")

      PostToIndividualPingEndpointWorker.new.perform("https://notification.com", { "a" => 1 })
    end
  end
end
