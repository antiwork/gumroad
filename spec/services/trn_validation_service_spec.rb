# frozen_string_literal: true

require "spec_helper"

describe TrnValidationService do
  it "returns true when valid TRN is provided" do
    trn_id = "123456789012345"
    expect(described_class.new(trn_id).process).to be(true)
  end

  it "returns false when nil TRN is provided" do
    expect(described_class.new(nil).process).to be(false)
  end

  it "returns false when blank TRN is provided" do
    expect(described_class.new("   ").process).to be(false)
  end

  it "returns false when TRN with invalid length is provided" do
    expect(described_class.new("12345").process).to be(false)
    expect(described_class.new("1234567890123456").process).to be(false)
  end
end
