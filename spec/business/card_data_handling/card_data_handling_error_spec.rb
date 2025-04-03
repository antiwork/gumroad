# frozen_string_literal: true

require "spec_helper"

describe CardDataHandlingError do
  describe "with message" do
    let(:subject) { CardDataHandlingError.new("the-error-message") }

    it "message should be accessible" do
      expect(subject.error_message).to eq "the-error-message"
    end

    it "card error code should be nil" do
      expect(subject.card_error_code).to be(nil)
    end

    it "is not a card error" do
      expect(subject.is_card_error?).to be(false)
    end
  end

  describe "with message and card data code" do
    let(:subject) { CardDataHandlingError.new("the-error-message", "card-error-code") }

    it "message should be accessible" do
      expect(subject.error_message).to eq "the-error-message"
    end

    it "card error code should be accessible" do
      expect(subject.card_error_code).to eq "card-error-code"
    end

    it "is a card error" do
      expect(subject.is_card_error?).to be(true)
    end
  end
end
