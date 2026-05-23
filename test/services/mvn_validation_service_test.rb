# frozen_string_literal: true

require "test_helper"

class MvaValidationServiceTest < ActiveSupport::TestCase
  self.described_class = MvaValidationService



  context_ MvaValidationService do
    before do
      @vatstack_response = {
        "id" => "5e5a894fa5807929777ad9c7",
        "active" => true,
        "company_address" => "Søndre gate 15, 7011 TRONDHEIM",
        "company_name" => "DANSKE BANK",
        "company_type" => "NUF",
        "consultation_number" => nil,
        "valid" => true,
        "valid_format" => true,
        "vat_number" => "977074010",
        "country_code" => "NO",
        "query" => "977074010MVA",
        "type" => "no_vat",
        "requested" => "2020-02-29T00:00:00.000Z",
        "created" => "2020-02-29T15:54:55.029Z",
        "updated" => "2020-02-29T15:54:55.029Z"
      }
    end

  test "returns true when valid mva is provided" do
      mva_id = "977074010MVA"

      expect(HTTParty).to receive(:post).with("https://api.vatstack.com/v1/validations", timeout: 5, body: { "type" => "no_vat", "query" => mva_id }, headers: hash_including("X-API-KEY")).and_return(@vatstack_response)

      expect(described_class.new(mva_id).process).to be(true)
    end

  test "returns false when valid mva is provided, but government services are down" do
      mva_id = "977074010MVA"

      expect(HTTParty).to receive(:post).with("https://api.vatstack.com/v1/validations", timeout: 5, body: { "type" => "no_vat", "query" => mva_id }, headers: hash_including("X-API-KEY")).and_return(@vatstack_response.merge("valid" => nil))

      expect(described_class.new(mva_id).process).to be(false)
    end

  test "returns false when nil mva is provided" do
      expect(described_class.new(nil).process).to be(false)
    end

  test "returns false when blank mva is provided" do
      expect(described_class.new("   ").process).to be(false)
    end

  test "returns false when mva with invalid format is provided" do
      mva_id = "some-invalid-id"
      query_response = "SOMEINVALIDID"

      invalid_input_response = {
        "code" => "INVALID_INPUT",
        "query" => query_response,
        "valid" => false,
        "valid_format" => false
      }

      expect(HTTParty).to receive(:post).with("https://api.vatstack.com/v1/validations", timeout: 5, body: { "type" => "no_vat", "query" => mva_id }, headers: hash_including("X-API-KEY")).and_return(invalid_input_response)

      expect(described_class.new(mva_id).process).to be(false)
    end

  test "returns false when invalid mva is provided" do
      mva_id = "11111111111"

      expect(HTTParty).to receive(:post).with("https://api.vatstack.com/v1/validations", timeout: 5, body: { "type" => "no_vat", "query" => mva_id }, headers: hash_including("X-API-KEY")).and_return(@vatstack_response.merge("valid" => false))

      expect(described_class.new(mva_id).process).to be(false)
    end

  test "returns false when inactive mva is provided" do
      mva_id = "12345678901"

      expect(HTTParty).to receive(:post).with("https://api.vatstack.com/v1/validations", timeout: 5, body: { "type" => "no_vat", "query" => mva_id }, headers: hash_including("X-API-KEY")).and_return(@vatstack_response.merge("active" => false))

      expect(described_class.new(mva_id).process).to be(false)
    end
  end
end
