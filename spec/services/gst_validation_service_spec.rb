# frozen_string_literal: true

require "spec_helper"

describe GstValidationService do
  before do
    stub_const("IRAS_APEX_API_KEY", nil)
    stub_const("IRAS_ENDPOINT", "https://apisandbox.iras.gov.sg/iras/sb/GSTListing/SearchGSTRegistered")
  end

  it "returns true when valid a gst id is provided" do
    gst_id = "T9100001B"

    success_response = {
      "returnCode" => "10",
      "data" => {
        "gstRegistrationNumber" => "T9100001B",
        "name" => "GUMROAD, INC.",
        "RegisteredFrom" => "2020-01-01T00:00:00",
        "Status" => "Registered",
        "Remarks" => "Currently registered under Simplified Pay-only Regime"
      },
      "info" => {
        "fieldInfoList" => []
      }
    }

    expect(HTTParty).to receive(:post).with("https://apisandbox.iras.gov.sg/iras/sb/GSTListing/SearchGSTRegistered", timeout: 5, body: "{\"clientID\":\"#{IRAS_API_ID}\",\"regID\":\"#{gst_id}\"}", headers: hash_including("X-IBM-Client-Secret")).and_return(success_response)

    expect(described_class.new(gst_id).process).to be(true)
  end

  it "returns false when nil gst id is provided" do
    expect(described_class.new(nil).process).to be(false)
  end

  it "returns false when a blank gst id is provided" do
    expect(described_class.new("   ").process).to be(false)
  end

  it "returns false when a valid gst id is provided, but IRAS returns a 500" do
    gst_id = "T9100001B"

    internal_error_response = {
      "httpCode" => "500",
      "httpMessage" => "Internal Server Error",
      "moreInformation" => "can't come to the phone right now, leave a message"
    }

    expect(HTTParty).to receive(:post).with("https://apisandbox.iras.gov.sg/iras/sb/GSTListing/SearchGSTRegistered", timeout: 5, body: "{\"clientID\":\"#{IRAS_API_ID}\",\"regID\":\"#{gst_id}\"}", headers: hash_including("X-IBM-Client-Secret")).and_return(internal_error_response)

    expect(described_class.new(gst_id).process).to be(false)
  end

  it "returns false when IRAS cannot find a match for the provided gst id" do
    gst_id = "M90379350P"

    not_found_response = {
      "returnCode " => "20",
      "info" => {
        "fieldInfoList" => [],
        "message" => "No match data found",
        "messageCode" => "400033"
      }
    }

    expect(HTTParty).to receive(:post).with("https://apisandbox.iras.gov.sg/iras/sb/GSTListing/SearchGSTRegistered", timeout: 5, body: "{\"clientID\":\"#{IRAS_API_ID}\",\"regID\":\"#{gst_id}\"}", headers: hash_including("X-IBM-Client-Secret")).and_return(not_found_response)

    expect(described_class.new(gst_id).process).to be(false)
  end

  it "returns false when a gst id is provided with an invalid format" do
    gst_id = "asdf"

    invalid_input_response = {
      "returnCode" => "30",
      "info" => {
        "fieldInfoList" => [
          {
            "field" => "regId",
            "message" => "Value is not valid"
          }
        ],
        "message" => "Arguments Error",
        "messageCode" => "850301"
      }
    }

    expect(HTTParty).to receive(:post).with("https://apisandbox.iras.gov.sg/iras/sb/GSTListing/SearchGSTRegistered", timeout: 5, body: "{\"clientID\":\"#{IRAS_API_ID}\",\"regID\":\"#{gst_id}\"}", headers: hash_including("X-IBM-Client-Secret")).and_return(invalid_input_response)

    expect(described_class.new(gst_id).process).to be(false)
  end

  context "with an APEX API key" do
    let(:gst_id) { "T9100001B" }
    let(:endpoint) { "https://sandbox.api.gov.sg/iras/GSTListing/v1/SearchGSTRegistered" }
    let(:registered_response) do
      { "returnCode" => "10", "data" => { "Status" => "Registered" } }
    end

    before do
      stub_const("IRAS_APEX_API_KEY", "test-apex-api-key")
      stub_const("IRAS_ENDPOINT", endpoint)
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    end

    it "authenticates with only the APEX key and sends only the GST registration number" do
      expect(HTTParty).to receive(:post).with(
        endpoint,
        timeout: 5,
        body: { regID: gst_id }.to_json,
        headers: {
          "x-apex-apikey" => "test-apex-api-key",
          "accept" => "application/json",
          "content-type" => "application/json"
        }
      ).and_return(registered_response)

      expect(described_class.new(gst_id).process).to be(true)
    end

    it "returns false for a deregistered business" do
      expect(HTTParty).to receive(:post).once.with(endpoint, anything).and_return(
        "returnCode" => "10", "data" => { "Status" => "Deregistered" }
      )

      expect(described_class.new(gst_id).process).to be(false)
    end

    [
      { "returnCode" => "20", "info" => { "message" => "No match data found" } },
      { "returnCode" => "30", "info" => { "message" => "Arguments Error" } },
      { "httpCode" => "401", "httpMessage" => "Unauthorized" },
      { "httpCode" => "500", "httpMessage" => "Internal Server Error" }
    ].each do |response|
      it "returns false without falling back to IBM for #{response.dig("info", "message") || response["httpMessage"]}" do
        expect(HTTParty).to receive(:post).once.with(endpoint, anything).and_return(response)

        expect(described_class.new(gst_id).process).to be(false)
      end
    end

    [nil, "", "   "].each do |blank_gst_id|
      it "does not send a request for #{blank_gst_id.inspect}" do
        expect(HTTParty).not_to receive(:post)

        expect(described_class.new(blank_gst_id).process).to be(false)
      end
    end

    it "does not retry the legacy endpoint when the APEX connection times out" do
      expect(HTTParty).to receive(:post).once.with(endpoint, anything).and_raise(Net::ReadTimeout)

      expect { described_class.new(gst_id).process }.to raise_error(Net::ReadTimeout)
    end

    it "caches validation results for ten minutes" do
      expect(HTTParty).to receive(:post).twice.with(endpoint, anything).and_return(registered_response)

      expect(described_class.new(gst_id).process).to be(true)
      travel_to(9.minutes.from_now) do
        expect(described_class.new(gst_id).process).to be(true)
      end
      travel_to(11.minutes.from_now) do
        expect(described_class.new(gst_id).process).to be(true)
      end
    end

    it "does not reuse validation results cached by the legacy endpoint" do
      legacy_endpoint = "https://apisandbox.iras.gov.sg/iras/sb/GSTListing/SearchGSTRegistered"
      stub_const("IRAS_APEX_API_KEY", nil)
      stub_const("IRAS_ENDPOINT", legacy_endpoint)
      expect(HTTParty).to receive(:post).once.with(legacy_endpoint, anything).and_return("returnCode" => "20")

      expect(described_class.new(gst_id).process).to be(false)

      stub_const("IRAS_APEX_API_KEY", "test-apex-api-key")
      stub_const("IRAS_ENDPOINT", endpoint)
      expect(HTTParty).to receive(:post).once.with(endpoint, anything).and_return(registered_response)

      expect(described_class.new(gst_id).process).to be(true)
    end
  end
end
