# frozen_string_literal: true

require "spec_helper"

describe UsZipCodes do
  describe "#identify_state_code" do
    it "returns the state for a zip code that exists" do
      expect(UsZipCodes.identify_state_code("94104")).to eq("CA")
    end

    it "returns the state for a zip code with space in front" do
      expect(UsZipCodes.identify_state_code("  94104")).to eq("CA")
    end

    it "returns the state for a zip code with space in back" do
      expect(UsZipCodes.identify_state_code("94104  ")).to eq("CA")
    end

    it "returns the state for a zip+4" do
      expect(UsZipCodes.identify_state_code("94104-5401")).to eq("CA")
    end

    it "returns the state for a zip+4 with single space in between" do
      expect(UsZipCodes.identify_state_code("94104 5401")).to eq("CA")
    end

    it "returns the state for a zip+4 with no character in between" do
      expect(UsZipCodes.identify_state_code("941045401")).to eq("CA")
    end

    it "returns nil when zip code is less than 5 digits" do
      expect(UsZipCodes.identify_state_code("9410")).to be_nil
    end

    it "returns nil when zip code contains non-digits" do
      expect(UsZipCodes.identify_state_code("94l04")).to be_nil
    end

    it "returns nil when zip code is not a valid zip+4 structure" do
      expect(UsZipCodes.identify_state_code("94104-540")).to be_nil
    end

    it "returns nil when zip code is nil" do
      expect(UsZipCodes.identify_state_code(nil)).to be_nil
    end

    it "returns nil when zip code is empty" do
      expect(UsZipCodes.identify_state_code("")).to be_nil
    end
  end
end
