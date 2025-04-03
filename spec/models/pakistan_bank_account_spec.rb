# frozen_string_literal: true

require "spec_helper"

describe PakistanBankAccount do
  describe "#bank_account_type" do
    it "returns Pakistan" do
      expect(create(:pakistan_bank_account).bank_account_type).to eq("PK")
    end
  end

  describe "#country" do
    it "returns PK" do
      expect(create(:pakistan_bank_account).country).to eq("PK")
    end
  end

  describe "#currency" do
    it "returns pkr" do
      expect(create(:pakistan_bank_account).currency).to eq("pkr")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:pakistan_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAAPKKAXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:pakistan_bank_account, account_number_last_four: "6702").account_number_visual).to eq("******6702")
    end
  end

  describe "#validate_bank_code" do
    it "allows 8 to 11 characters only" do
      expect(build(:pakistan_bank_account, bank_code: "AAAAPKKAXXX")).to be_valid
      expect(build(:pakistan_bank_account, bank_code: "AAAAPKKA")).to be_valid
      expect(build(:pakistan_bank_account, bank_code: "AAAAPKK")).not_to be_valid
      expect(build(:pakistan_bank_account, bank_code: "AAAAPKKAXXXX")).not_to be_valid
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(build(:pakistan_bank_account)).to be_valid
      expect(build(:pakistan_bank_account, account_number: "PK36SCBL0000001123456702")).to be_valid

      pk_bank_account = build(:pakistan_bank_account, account_number: "PK12345")
      expect(pk_bank_account).to_not be_valid
      expect(pk_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      pk_bank_account = build(:pakistan_bank_account, account_number: "PK36SCBL00000011234567021")
      expect(pk_bank_account).to_not be_valid
      expect(pk_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      pk_bank_account = build(:pakistan_bank_account, account_number: "PK36SCBL000000112345670")
      expect(pk_bank_account).to_not be_valid
      expect(pk_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      pk_bank_account = build(:pakistan_bank_account, account_number: "PKABCDE")
      expect(pk_bank_account).to_not be_valid
      expect(pk_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
