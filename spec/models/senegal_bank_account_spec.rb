# frozen_string_literal: true

require "spec_helper"

describe SenegalBankAccount do
  describe "#bank_account_type" do
    it "returns senegal" do
      expect(create(:senegal_bank_account).bank_account_type).to eq("SN")
    end
  end

  describe "#country" do
    it "returns SN" do
      expect(create(:senegal_bank_account).country).to eq("SN")
    end
  end

  describe "#currency" do
    it "returns xof" do
      expect(create(:senegal_bank_account).currency).to eq("xof")
    end
  end

  describe "#routing_number" do
    it "returns nil" do
      expect(create(:senegal_bank_account).routing_number).to be nil
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number with country code prefixed" do
      expect(create(:senegal_bank_account, account_number_last_four: "3035").account_number_visual).to eq("******3035")
    end
  end

  describe "#validate_account_number" do
    let(:message) { "The account number is invalid. Enter your 28-character IBAN: SN followed by 26 characters." }

    it "accepts a 28-character IBAN with valid check digits" do
      expect(build(:senegal_bank_account)).to be_valid
      expect(build(:senegal_bank_account, account_number: "SN08SN0100152000048500003035")).to be_valid
      expect(build(:senegal_bank_account, account_number: "SN08SN1530931231210000007678")).to be_valid
    end

    it "rejects values Stripe rejects" do
      [
        "SN08SN1530931231210000007679", # 28 chars, check digits do not compute
        "SN62370400440532013001",       # 22 chars
        "SN08SN01001520000485000030355", # 29 chars
        "SN08SN010015200004850",
        "SNSNSNSNSNSNSNSNSNSNSNSN",
        "012345678",
        "ABCDEFGHIJKLMNOPQRSTUV",
        "sn08sn0100152000048500003035",
        "SN08 SN01 0015 2000 0485 0000 3035",
      ].each do |account_number|
        sn_bank_account = build(:senegal_bank_account, account_number:)
        expect(sn_bank_account).to_not be_valid
        expect(sn_bank_account.errors.full_messages.to_sentence).to eq(message)
      end
    end

    it "leaves an already-persisted non-conforming number alone on an unrelated save" do
      sn_bank_account = build(:senegal_bank_account, account_number: "SN62370400440532013001", account_number_last_four: "3001")
      sn_bank_account.save!(validate: false)

      expect { sn_bank_account.reload.mark_deleted! }.to_not raise_error
      expect(sn_bank_account.reload).to be_deleted
    end
  end
end
