# frozen_string_literal: true

require "test_helper"

class VatValidationServiceTest < ActiveSupport::TestCase
  self.described_class = VatValidationService
  self.rspec_metadata = { vcr: true }



  context_ VatValidationService, :vcr do
  context_ "#process" do
  test "returns false when provided vat is nil" do
        expect(described_class.new(nil).process).to be(false)
      end

  test "returns false when invalid vat is provided" do
        expect(described_class.new("xxx").process).to be(false)
      end

  test "returns true when valid vat is provided" do
        expect(described_class.new("IE6388047V").process).to be(true)
      end

  test "works well with GB numbers" do
        expect(described_class.new("GB902194939").process).to be(true)
      end

  test "falls back to local vat validation when VIES hits timeout/rate limits" do
        expect_any_instance_of(Valvat).to receive(:exists?).and_raise(Valvat::RateLimitError)
        expect_any_instance_of(Valvat).to receive(:valid?)
        described_class.new("IE6388047V").process
      end

  test "passes a 30-second timeout to the VIES lookup and falls back on Net::ReadTimeout" do
        expect_any_instance_of(Valvat).to receive(:exists?)
          .with(requester: GUMROAD_VAT_REGISTRATION_NUMBER, http: { open_timeout: 30, read_timeout: 30 })
          .and_raise(Net::ReadTimeout)
        expect_any_instance_of(Valvat).to receive(:valid?)
        described_class.new("IE6388047V").process
      end
    end
  end
end
