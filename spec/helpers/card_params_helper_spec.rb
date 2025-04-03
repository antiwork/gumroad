# frozen_string_literal: true

require "spec_helper"

describe CardParamsHelper do
  describe ".get_card_data_handling_mode" do
    describe "with valid mode" do
      let(:params) { { card_data_handling_mode: "stripejs.0" } }

      it "returns the mode" do
        expect(CardParamsHelper.get_card_data_handling_mode(params)).to eq "stripejs.0"
      end
    end

    describe "with invalid mode" do
      let(:params) { { card_data_handling_mode: "jedi-force" } }

      it "returns nil" do
        expect(CardParamsHelper.get_card_data_handling_mode(params)).to be(nil)
      end
    end
  end

  describe ".check_for_errors" do
    describe "with no errors" do
      let(:params) { { card_data_handling_mode: "stripejs.0" } }

      it "returns nil" do
        expect(CardParamsHelper.check_for_errors(params)).to be(nil)
      end
    end

    describe "with invalid card data handling mode" do
      let(:params) { { card_data_handling_mode: "jedi-force" } }

      it "returns nil" do
        expect(CardParamsHelper.check_for_errors(params)).to be(nil)
      end
    end

    describe "with errors (stripe)" do
      let(:params) do
        {
          card_data_handling_mode: "stripejs.0",
          stripe_error: {
            message: "The card was declined.",
            code: "card_declined"
          }
        }
      end

      it "returns an error object" do
        expect(CardParamsHelper.check_for_errors(params)).to be_a(CardDataHandlingError)
      end

      it "returns the error message" do
        expect(CardParamsHelper.check_for_errors(params).error_message).to eq "The card was declined."
      end

      it "returns the error code" do
        expect(CardParamsHelper.check_for_errors(params).card_error_code).to eq "card_declined"
      end
    end
  end

  describe ".build_chargeable" do
    describe "with invalid card data handling mode" do
      let(:params) { { card_data_handling_mode: "jedi-force" } }

      it "returns nil" do
        expect(CardParamsHelper.build_chargeable(params)).to be(nil)
      end
    end

    describe "with valid card data handling mode" do
      let(:params) { { card_data_handling_mode: "stripejs.0" } }

      it "returns nil" do
        chargeable_double = double("chargeable")
        expect(ChargeProcessor).to receive(:get_chargeable_for_params).with(params, nil).and_return(chargeable_double)
        expect(CardParamsHelper.build_chargeable(params)).to eq chargeable_double
      end
    end
  end
end
