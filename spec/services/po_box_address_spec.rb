# frozen_string_literal: true

require "spec_helper"

describe PoBoxAddress do
  describe ".match?" do
    it "is false for a blank address" do
      expect(described_class.match?(nil)).to eq(false)
      expect(described_class.match?("")).to eq(false)
      expect(described_class.match?("   ")).to eq(false)
    end

    it "recognises the spelled-out forms however they are punctuated or spaced" do
      [
        "PO Box 65",
        "P.O. Box 65",
        "p o box 65",
        "POBOX65",
        "P O B O X 65",
        "P.O.B.O.X. 65",
        "Post Office Box 65",
        "post office box 65",
        "Unit 3, PO Box 65, Somewhere",
      ].each do |address|
        expect(described_class.match?(address)).to eq(true), "expected #{address.inspect} to be treated as a P.O. Box"
      end
    end

    it "recognises the short rural forms the postal services also publish" do
      [
        "Box 65",
        "Box 65, RR 2",
        "RR 2 Box 65",
        "BOX #65",
        "Box no. 65",
        "Box No 65",
      ].each do |address|
        expect(described_class.match?(address)).to eq(true), "expected #{address.inspect} to be treated as a P.O. Box"
      end
    end

    it "leaves street addresses that merely contain 'box' alone" do
      [
        "123 Boxwood Lane",
        "5 Sandbox Street",
        "12 Mailbox Road",
        "Boxwood Avenue",
        "NW-22-34-19-W2",
        "1234 Main Street",
      ].each do |address|
        expect(described_class.match?(address)).to eq(false), "expected #{address.inspect} not to be treated as a P.O. Box"
      end
    end

    it "does not match a box word with no number after it" do
      expect(described_class.match?("Box Hill Avenue")).to eq(false)
    end
  end
end
