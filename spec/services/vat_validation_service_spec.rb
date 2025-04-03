# frozen_string_literal: true

require "spec_helper"

describe VatValidationService, :vcr do
  describe "#process" do
    it "returns false when provided vat is nil" do
      expect(described_class.new(nil).process).to be(false)
    end

    it "returns false when invalid vat is provided" do
      expect(described_class.new("xxx").process).to be(false)
    end

    it "returns true when valid vat is provided" do
      expect(described_class.new("IE6388047V").process).to be(true)
    end

    it "works well with GB numbers" do
      expect(described_class.new("GB902194939").process).to be(true)
    end

    it "falls back to local vat validation when VIES hits timeout/rate limits" do
      expect_any_instance_of(Valvat).to receive(:exists?).and_raise(Valvat::RateLimitError)
      expect_any_instance_of(Valvat).to receive(:valid?)
      described_class.new("IE6388047V").process
    end
  end
end
