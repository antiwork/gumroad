# frozen_string_literal: true

require "spec_helper"

describe UkBankAccount do
  describe "sort_code" do
    describe "is 6 digits with hyphens" do
      let(:uk_bank_account) { build(:uk_bank_account, sort_code: "06-21-11") }

      it "is valid" do
        expect(uk_bank_account).to be_valid
      end
    end

    describe "nil" do
      let(:uk_bank_account) { build(:uk_bank_account, sort_code: nil) }

      it "is not valid" do
        expect(uk_bank_account).not_to be_valid
      end
    end

    describe "is 6 digits without hyphens" do
      let(:uk_bank_account) { build(:uk_bank_account, sort_code: "123456") }

      it "is not valid" do
        expect(uk_bank_account).not_to be_valid
      end
    end

    describe "is 5 digits" do
      let(:uk_bank_account) { build(:uk_bank_account, sort_code: "12345") }

      it "is not valid" do
        expect(uk_bank_account).not_to be_valid
      end
    end

    describe "is 7 digits with hyphens" do
      let(:uk_bank_account) { build(:uk_bank_account, sort_code: "12-34-56-7") }

      it "is not valid" do
        expect(uk_bank_account).not_to be_valid
      end
    end

    describe "contains alpha characters with hyphens" do
      let(:uk_bank_account) { build(:uk_bank_account, sort_code: "12-34-5a") }

      it "is not valid" do
        expect(uk_bank_account).not_to be_valid
      end
    end
  end

  describe "routing_number" do
    let(:uk_bank_account) { build(:uk_bank_account, sort_code: "45-37-80") }

    it "is the sort_code" do
      expect(uk_bank_account.routing_number).to eq("45-37-80")
    end
  end
end
