# frozen_string_literal: true

require "test_helper"

class TaxIdValidationServiceTest < ActiveSupport::TestCase
  self.described_class = TaxIdValidationService
  self.rspec_metadata = { vcr: true }



  context_ TaxIdValidationService, :vcr do
    let(:tax_id) { "528491" }
    let(:country_code) { "IS" }

  test "returns true when a valid tax id is provided" do
      expect(described_class.new(tax_id, country_code).process).to be(true)
    end

  test "returns false when the tax id is nil" do
      expect(described_class.new(nil, country_code).process).to be(false)
    end

  test "returns false when the tax id is empty" do
      expect(described_class.new("", country_code).process).to be(false)
    end

  test "returns false when the country code is nil" do
      expect(described_class.new(tax_id, nil).process).to be(false)
    end

  test "returns false when the country code is empty" do
      expect(described_class.new(tax_id, "").process).to be(false)
    end

  test "returns false when the tax id is not valid" do
      expect(described_class.new("1234567890", country_code).process).to be(false)
    end
  end
end
