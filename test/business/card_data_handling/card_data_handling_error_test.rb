# frozen_string_literal: true

require "test_helper"

class CardDataHandlingErrorTest < ActiveSupport::TestCase
  self.described_class = CardDataHandlingError



  context_ CardDataHandlingError do
  context_ "with message" do
      let(:subject) { CardDataHandlingError.new("the-error-message") }

  test "message should be accessible" do
        expect(subject.error_message).to eq "the-error-message"
      end

  test "card error code should be nil" do
        expect(subject.card_error_code).to be(nil)
      end

  test "is not a card error" do
        expect(subject.is_card_error?).to be(false)
      end
    end

  context_ "with message and card data code" do
      let(:subject) { CardDataHandlingError.new("the-error-message", "card-error-code") }

  test "message should be accessible" do
        expect(subject.error_message).to eq "the-error-message"
      end

  test "card error code should be accessible" do
        expect(subject.card_error_code).to eq "card-error-code"
      end

  test "is a card error" do
        expect(subject.is_card_error?).to be(true)
      end
    end
  end
end
