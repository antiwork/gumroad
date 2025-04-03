# frozen_string_literal: true

require "spec_helper"

describe AustralianBankAccount do
  describe "bsb_number" do
    describe "is 6 digits" do
      let(:australian_bank_account) { build(:australian_bank_account, bsb_number: "062111") }

      it "is valid" do
        expect(australian_bank_account).to be_valid
      end
    end

    describe "nil" do
      let(:australian_bank_account) { build(:australian_bank_account, bsb_number: nil) }

      it "is not valid" do
        expect(australian_bank_account).not_to be_valid
      end
    end

    describe "is 5 digits" do
      let(:australian_bank_account) { build(:australian_bank_account, bsb_number: "12345") }

      it "is not valid" do
        expect(australian_bank_account).not_to be_valid
      end
    end

    describe "is 7 digits" do
      let(:australian_bank_account) { build(:australian_bank_account, bsb_number: "1234567") }

      it "is not valid" do
        expect(australian_bank_account).not_to be_valid
      end
    end

    describe "contains alpha characters" do
      let(:australian_bank_account) { build(:australian_bank_account, bsb_number: "12345a") }

      it "is not valid" do
        expect(australian_bank_account).not_to be_valid
      end
    end
  end

  describe "routing_number" do
    let(:australian_bank_account) { build(:australian_bank_account, bsb_number: "453780") }

    it "is a concat of institution_number, hyphen and bsb_number" do
      expect(australian_bank_account.routing_number).to eq("453780")
    end
  end
end
