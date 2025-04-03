# frozen_string_literal: true

require "spec_helper"

describe GstValidationService do
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
end
