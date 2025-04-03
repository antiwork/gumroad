# frozen_string_literal: true

require "spec_helper"

describe OmanVatNumberValidationService do
  it "returns true when valid VAT number is provided" do
    vat_number = "OM1234567890"
    expect(described_class.new(vat_number).process).to be(true)
  end

  it "returns false when nil VAT number is provided" do
    expect(described_class.new(nil).process).to be(false)
  end

  it "returns false when blank VAT number is provided" do
    expect(described_class.new("   ").process).to be(false)
  end

  it "returns false when VAT number with invalid format is provided" do
    expect(described_class.new("OM123456").process).to be(false)
    expect(described_class.new("ON1234567890").process).to be(false)
    expect(described_class.new("om1234567890").process).to be(false)
    expect(described_class.new("1234567890").process).to be(false)
    expect(described_class.new("OMABCDEFGHIJ").process).to be(false)
  end
end
