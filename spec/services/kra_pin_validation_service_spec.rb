# frozen_string_literal: true

require "spec_helper"

describe KraPinValidationService do
  it "returns true when valid KRA PIN is provided" do
    kra_pin = "A123456789P"
    expect(described_class.new(kra_pin).process).to be(true)
  end

  it "returns false when nil KRA PIN is provided" do
    expect(described_class.new(nil).process).to be(false)
  end

  it "returns false when blank KRA PIN is provided" do
    expect(described_class.new("   ").process).to be(false)
  end

  it "returns false when KRA PIN with invalid format is provided" do
    expect(described_class.new("123456789").process).to be(false)
    expect(described_class.new("A12345678PP").process).to be(false)
    expect(described_class.new("123456789P").process).to be(false)
    expect(described_class.new("A123456789").process).to be(false)
  end
end
