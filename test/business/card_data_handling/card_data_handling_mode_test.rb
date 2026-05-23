# frozen_string_literal: true

require "test_helper"

class CardDataHandlingModeTest < ActiveSupport::TestCase
  self.described_class = CardDataHandlingMode



  context_ CardDataHandlingMode do
  test "has the correct value for modes" do
      expect(CardDataHandlingMode::TOKENIZE_VIA_STRIPEJS).to eq "stripejs.0"
    end

  test "has the correct valid modes" do
      expect(CardDataHandlingMode::VALID_MODES).to include("stripejs.0")
    end

  test "maps each card data handling modeo to the correct charge processor" do
      expect(CardDataHandlingMode::VALID_MODES).to include("stripejs.0" => StripeChargeProcessor.charge_processor_id)
    end

  context_ ".is_valid" do
  context_ "with valid modes" do
  context_ "stripejs.0" do
          let(:mode) { "stripejs.0" }
  test "returns true" do
            expect(CardDataHandlingMode.is_valid(mode)).to eq(true)
          end
        end
      end

  context_ "with a invalid modes" do
  context_ "clearly invalid mode" do
          let(:mode) { "jedi-mode" }
  test "returns false" do
            expect(CardDataHandlingMode.is_valid(mode)).to eq(false)
          end
        end

  context_ "mix valid and invalid modes" do
          let(:mode) { "stripejs.0,jedi-mode" }
  test "returns false" do
            expect(CardDataHandlingMode.is_valid(mode)).to eq(false)
          end
        end
      end
    end

  context_ ".get_card_data_handling_mode" do
  test "returns stripejs" do
        expect(CardDataHandlingMode.get_card_data_handling_mode(nil)).to eq "stripejs.0"
      end
    end
  end
end
