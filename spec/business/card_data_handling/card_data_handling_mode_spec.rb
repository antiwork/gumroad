# frozen_string_literal: true

require "spec_helper"

describe CardDataHandlingMode do
  it "has the correct value for modes" do
    expect(CardDataHandlingMode::TOKENIZE_VIA_STRIPEJS).to eq "stripejs.0"
  end

  it "has the correct valid modes" do
    expect(CardDataHandlingMode::VALID_MODES).to include("stripejs.0")
  end

  it "maps each card data handling modeo to the correct charge processor" do
    expect(CardDataHandlingMode::VALID_MODES).to include("stripejs.0" => StripeChargeProcessor.charge_processor_id)
  end

  describe ".is_valid" do
    context "with valid modes" do
      context "stripejs.0" do
        let(:mode) { "stripejs.0" }
        it "returns true" do
          expect(CardDataHandlingMode.is_valid(mode)).to eq(true)
        end
      end
    end

    context "with a invalid modes" do
      context "clearly invalid mode" do
        let(:mode) { "jedi-mode" }
        it "returns false" do
          expect(CardDataHandlingMode.is_valid(mode)).to eq(false)
        end
      end

      context "mix valid and invalid modes" do
        let(:mode) { "stripejs.0,jedi-mode" }
        it "returns false" do
          expect(CardDataHandlingMode.is_valid(mode)).to eq(false)
        end
      end
    end
  end

  describe ".get_card_data_handling_mode" do
    it "returns stripejs" do
      expect(CardDataHandlingMode.get_card_data_handling_mode(nil)).to eq "stripejs.0"
    end
  end
end
