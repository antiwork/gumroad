# frozen_string_literal: true

require "spec_helper"

describe AbnValidationService do
  before do
    @vatstack_response = {
      "active" => true,
      "company_address" => "NSW 2020",
      "company_name" => "KANGAROO AIRWAYS LIMITED",
      "company_type" => "PUB",
      "consultation_number" => nil,
      "country_code" => "AU",
      "created" => "2022-02-13T16:09:08.189Z",
      "external_id" => nil,
      "id" => "62092d24a1f0d913207815ce",
      "query" => "51824753556",
      "requested" => "2022-02-13T16:09:08.186Z",
      "type" => "au_gst",
      "updated" => "2022-02-13T16:09:08.189Z",
      "valid" => true,
      "valid_format" => true,
      "vat_number" => "51824753556"
    }
  end

  it "returns true when valid abn is provided" do
    abn_id = "51824753556"

    expect(HTTParty).to receive(:post).with("https://api.vatstack.com/v1/validations", timeout: 5, body: { "type" => "au_gst", "query" => abn_id }, headers: hash_including("X-API-KEY")).and_return(@vatstack_response)

    expect(described_class.new(abn_id).process).to be(true)
  end

  it "returns false when valid abn is provided, but government services are down" do
    abn_id = "51824753556"

    expect(HTTParty).to receive(:post).with("https://api.vatstack.com/v1/validations", timeout: 5, body: { "type" => "au_gst", "query" => abn_id }, headers: hash_including("X-API-KEY")).and_return(@vatstack_response.merge("valid" => nil))

    expect(described_class.new(abn_id).process).to be(false)
  end

  it "returns false when nil abn is provided" do
    expect(described_class.new(nil).process).to be(false)
  end

  it "returns false when blank abn is provided" do
    expect(described_class.new("   ").process).to be(false)
  end

  it "returns false when abn with invalid format is provided" do
    abn_id = "some-invalid-id"
    query_response = "SOMEINVALIDID"

    invalid_input_response = {
      "code" => "INVALID_INPUT",
      "query" => query_response,
      "valid" => false,
      "valid_format" => false
    }

    expect(HTTParty).to receive(:post).with("https://api.vatstack.com/v1/validations", timeout: 5, body: { "type" => "au_gst", "query" => abn_id }, headers: hash_including("X-API-KEY")).and_return(invalid_input_response)

    expect(described_class.new(abn_id).process).to be(false)
  end

  it "returns false when invalid abn is provided" do
    abn_id = "11111111111"

    expect(HTTParty).to receive(:post).with("https://api.vatstack.com/v1/validations", timeout: 5, body: { "type" => "au_gst", "query" => abn_id }, headers: hash_including("X-API-KEY")).and_return(@vatstack_response.merge("valid" => false))

    expect(described_class.new(abn_id).process).to be(false)
  end

  it "returns false when inactive abn is provided" do
    abn_id = "12345678901"

    expect(HTTParty).to receive(:post).with("https://api.vatstack.com/v1/validations", timeout: 5, body: { "type" => "au_gst", "query" => abn_id }, headers: hash_including("X-API-KEY")).and_return(@vatstack_response.merge("active" => false))

    expect(described_class.new(abn_id).process).to be(false)
  end
end
