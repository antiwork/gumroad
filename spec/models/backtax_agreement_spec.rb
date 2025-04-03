# frozen_string_literal: true

require "spec_helper"

describe BacktaxAgreement do
  describe "validation" do
    it "is valid with expected parameters" do
      expect(build(:backtax_agreement)).to be_valid
    end

    it "validates the presence of a signature" do
      expect(build(:backtax_agreement, signature: nil)).to be_invalid
    end

    it "validates the inclusion of jurisdiction within a certain set" do
      expect(build(:backtax_agreement, jurisdiction: "United States")).to be_invalid
    end
  end
end
