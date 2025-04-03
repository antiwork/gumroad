# frozen_string_literal: true

require "spec_helper"

describe "Utilities" do
  describe "cors_preview_policy" do
    it "returns cors preview policy" do
      str = "eyJleHBpcmF0aW9uIjoiMjAxMy0wMS0wMVQwMDoxMDowMFoiLCJjb25kaXRpb25zIjp" \
            "beyJidWNrZXQiOiJndW1yb2FkLXNwZWNzIn0seyJhY2wiOiJwdWJsaWMtcmVhZCJ9LF" \
            "sic3RhcnRzLXdpdGgiLCIka2V5IiwiIl0sWyJzdGFydHMtd2l0aCIsIiRDb250ZW50L" \
            "VR5cGUiLCIiXV19"
      travel_to(Time.zone.parse("2013-01-01")) do
        expect(Utilities.cors_preview_policy).to eq(str)
      end
    end
  end

  describe "cors_preview_signature" do
    it "returns cors preview correctly" do
      travel_to(Time.zone.parse("2013-01-01")) do
        expect(Utilities.cors_preview_signature).to eq "5Xjo73gSPv3n1JyHOdwahs2gi08="
      end
    end
  end
end
