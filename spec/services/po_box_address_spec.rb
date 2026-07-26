# frozen_string_literal: true

require "spec_helper"

describe PoBoxAddress do
  describe ".match?" do
    it "matches the unmistakable post office box spellings" do
      ["PO Box 65", "P.O. Box 65", "p o box 65", "PO BOX 65, Rural Route 2", "Unit 3, PO Box 65"].each do |address|
        expect(described_class.match?(address)).to be(true), "expected #{address.inspect} to match"
      end
    end

    it "does not match a street address that merely mentions a box" do
      ["Box 65, RR 2", "12 Mailbox Road", "4 Boxwood Lane", "65 Post Road", "1 Boxing Club Street"].each do |address|
        expect(described_class.match?(address)).to be(false), "expected #{address.inspect} not to match"
      end
    end

    it "is false for a blank address" do
      expect(described_class.match?(nil)).to be(false)
      expect(described_class.match?("")).to be(false)
      expect(described_class.match?("   ")).to be(false)
    end
  end

  describe ".possible_match?" do
    it "matches everything the strict check matches" do
      ["PO Box 65", "P.O. Box 65", "p o box 65"].each do |address|
        expect(described_class.possible_match?(address)).to be(true), "expected #{address.inspect} to match"
      end
    end

    it "matches the bare box-and-number form rural sellers use" do
      ["Box 65, RR 2", "Box 65", "box65", "Box #65", "BOX 65 RR 2 Site 4", "Post Office Box 65"].each do |address|
        expect(described_class.possible_match?(address)).to be(true), "expected #{address.inspect} to match"
      end
    end

    it "does not match a street address that merely contains the letters box" do
      ["12 Mailbox Road", "4 Boxwood Lane", "Boxwood Crescent 4", "1 Boxing Club Street", "65 Post Road"].each do |address|
        expect(described_class.possible_match?(address)).to be(false), "expected #{address.inspect} not to match"
      end
    end

    it "is false for a blank address" do
      expect(described_class.possible_match?(nil)).to be(false)
      expect(described_class.possible_match?("")).to be(false)
    end
  end
end
