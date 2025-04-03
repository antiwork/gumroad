# frozen_string_literal: true

require "spec_helper"

describe FirsTinValidationService do
  it "returns true when valid FIRS TIN is provided" do
    firs_tin = "12345678-1234"
    expect(described_class.new(firs_tin).process).to be(true)
  end

  it "returns false when nil FIRS TIN is provided" do
    expect(described_class.new(nil).process).to be(false)
  end

  it "returns false when blank FIRS TIN is provided" do
    expect(described_class.new("   ").process).to be(false)
  end

  it "returns false when FIRS TIN with invalid format is provided" do
    expect(described_class.new("123456781234").process).to be(false)
    expect(described_class.new("12345678-123").process).to be(false)
    expect(described_class.new("1234567-1234").process).to be(false)
    expect(described_class.new("abcdefgh-1234").process).to be(false)
  end
end
