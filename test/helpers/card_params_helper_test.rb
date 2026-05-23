# frozen_string_literal: true

require "test_helper"

class CardParamsHelperTest < ActionView::TestCase
  self.described_class = CardParamsHelper
  tests CardParamsHelper



  context_ CardParamsHelper do
  context_ ".get_card_data_handling_mode" do
  context_ "with valid mode" do
        let(:params) { { card_data_handling_mode: "stripejs.0" } }

  test "returns the mode" do
          expect(CardParamsHelper.get_card_data_handling_mode(params)).to eq "stripejs.0"
        end
      end

  context_ "with invalid mode" do
        let(:params) { { card_data_handling_mode: "jedi-force" } }

  test "returns nil" do
          expect(CardParamsHelper.get_card_data_handling_mode(params)).to be(nil)
        end
      end
    end

  context_ ".check_for_errors" do
  context_ "with no errors" do
        let(:params) { { card_data_handling_mode: "stripejs.0" } }

  test "returns nil" do
          expect(CardParamsHelper.check_for_errors(params)).to be(nil)
        end
      end

  context_ "with invalid card data handling mode" do
        let(:params) { { card_data_handling_mode: "jedi-force" } }

  test "returns nil" do
          expect(CardParamsHelper.check_for_errors(params)).to be(nil)
        end
      end

  context_ "with errors (stripe)" do
        let(:params) do
          {
            card_data_handling_mode: "stripejs.0",
            stripe_error: {
              message: "The card was declined.",
              code: "card_declined"
            }
          }
        end

  test "returns an error object" do
          expect(CardParamsHelper.check_for_errors(params)).to be_a(CardDataHandlingError)
        end

  test "returns the error message" do
          expect(CardParamsHelper.check_for_errors(params).error_message).to eq "The card was declined."
        end

  test "returns the error code" do
          expect(CardParamsHelper.check_for_errors(params).card_error_code).to eq "card_declined"
        end
      end
    end

  context_ ".build_chargeable" do
  context_ "with invalid card data handling mode" do
        let(:params) { { card_data_handling_mode: "jedi-force" } }

  test "returns nil" do
          expect(CardParamsHelper.build_chargeable(params)).to be(nil)
        end
      end

  context_ "with valid card data handling mode" do
        let(:params) { { card_data_handling_mode: "stripejs.0" } }

  test "returns nil" do
          chargeable_double = double("chargeable")
          expect(ChargeProcessor).to receive(:get_chargeable_for_params).with(params, nil).and_return(chargeable_double)
          expect(CardParamsHelper.build_chargeable(params)).to eq chargeable_double
        end
      end
    end
  end
end
