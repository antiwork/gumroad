# frozen_string_literal: true

require "spec_helper"

describe TraTinValidationService do
  it "returns true when valid Tanzania TIN is provided" do
    tin = "12-345678-A"
    expect(described_class.new(tin).process).to be(true)
  end

  it "returns false when nil TIN is provided" do
    expect(described_class.new(nil).process).to be(false)
  end

  it "returns false when blank TIN is provided" do
    expect(described_class.new("   ").process).to be(false)
  end

  it "returns false when TIN with invalid format is provided" do
    expect(described_class.new("123-45678-B").process).to be(false)  # Wrong first segment length
    expect(described_class.new("12-34567-A").process).to be(false)   # Wrong middle segment length
    expect(described_class.new("12-345678-1").process).to be(false)  # Number instead of letter
    expect(described_class.new("12345678A").process).to be(false)    # Missing hyphens
    expect(described_class.new("ab-345678-A").process).to be(false)  # Letters instead of numbers
  end
end
