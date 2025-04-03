# frozen_string_literal: true

require "spec_helper"

describe CanadianBankAccount do
  describe "transit_number" do
    describe "is 5 digits" do
      let(:canadian_bank_account) { build(:canadian_bank_account, transit_number: "12345") }

      it "is valid" do
        expect(canadian_bank_account).to be_valid
      end
    end

    describe "nil" do
      let(:canadian_bank_account) { build(:canadian_bank_account, transit_number: nil) }

      it "is not valid" do
        expect(canadian_bank_account).not_to be_valid
      end
    end

    describe "is 4 digits" do
      let(:canadian_bank_account) { build(:canadian_bank_account, transit_number: "1234") }

      it "is not valid" do
        expect(canadian_bank_account).not_to be_valid
      end
    end

    describe "is 6 digits" do
      let(:canadian_bank_account) { build(:canadian_bank_account, transit_number: "123456") }

      it "is not valid" do
        expect(canadian_bank_account).not_to be_valid
      end
    end

    describe "contains alpha characters" do
      let(:canadian_bank_account) { build(:canadian_bank_account, transit_number: "1234a") }

      it "is not valid" do
        expect(canadian_bank_account).not_to be_valid
      end
    end
  end

  describe "institution_number" do
    describe "is 3 digits" do
      let(:canadian_bank_account) { build(:canadian_bank_account, institution_number: "123") }

      it "is valid" do
        expect(canadian_bank_account).to be_valid
      end
    end

    describe "nil" do
      let(:canadian_bank_account) { build(:canadian_bank_account, institution_number: nil) }

      it "is not valid" do
        expect(canadian_bank_account).not_to be_valid
      end
    end

    describe "is 2 digits" do
      let(:canadian_bank_account) { build(:canadian_bank_account, institution_number: "12") }

      it "is not valid" do
        expect(canadian_bank_account).not_to be_valid
      end
    end

    describe "is 4 digits" do
      let(:canadian_bank_account) { build(:canadian_bank_account, institution_number: "1234") }

      it "is not valid" do
        expect(canadian_bank_account).not_to be_valid
      end
    end

    describe "contains alpha characters" do
      let(:canadian_bank_account) { build(:canadian_bank_account, institution_number: "12a") }

      it "is not valid" do
        expect(canadian_bank_account).not_to be_valid
      end
    end
  end

  describe "routing_number" do
    let(:canadian_bank_account) { build(:canadian_bank_account, transit_number: "45678", institution_number: "123") }

    it "is a concat of institution_number, hyphen and transit_number" do
      expect(canadian_bank_account.routing_number).to eq("45678-123")
    end
  end
end
