# frozen_string_literal: true

require "spec_helper"

describe KoreaBankAccount do
  describe "#bank_account_type" do
    it "returns korea" do
      expect(create(:korea_bank_account).bank_account_type).to eq("KR")
    end
  end

  describe "#country" do
    it "returns KR" do
      expect(create(:korea_bank_account).country).to eq("KR")
    end
  end

  describe "#currency" do
    it "returns krw" do
      expect(create(:korea_bank_account).currency).to eq("krw")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 digits" do
      ba = create(:korea_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("SGSEKRSLXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:korea_bank_account, account_number_last_four: "8912").account_number_visual).to eq("******8912")
    end
  end

  describe "#validate_bank_code" do
    it "allows the 8-character SWIFT/BIC and its 11-character branch-suffixed form only" do
      expect(build(:korea_bank_account, bank_code: "NACFKRSE")).to be_valid
      expect(build(:korea_bank_account, bank_code: "NACFKRSEXXX")).to be_valid
      # Kakao Bank's BIC carries digits in the location pair and still resolves at Stripe.
      expect(build(:korea_bank_account, bank_code: "KAKOKR22")).to be_valid
      expect(build(:korea_bank_account, bank_code: "TESTKR00")).to be_valid

      expect(build(:korea_bank_account, bank_code: "ABCD")).not_to be_valid
      expect(build(:korea_bank_account, bank_code: "1234")).not_to be_valid
      expect(build(:korea_bank_account, bank_code: "TESTKR0")).not_to be_valid
      expect(build(:korea_bank_account, bank_code: "BANKKR001")).not_to be_valid
      expect(build(:korea_bank_account, bank_code: "CASHKR0012")).not_to be_valid
      expect(build(:korea_bank_account, bank_code: "TESTKR001234")).not_to be_valid
      expect(build(:korea_bank_account, bank_code: "nacfkrsexxx")).not_to be_valid
      expect(build(:korea_bank_account, bank_code: "NACFKRSExxx")).not_to be_valid
      expect(build(:korea_bank_account, bank_code: "NACFKRSEXXX\n")).not_to be_valid
    end

    it "does not re-validate a pre-existing code on an unrelated save" do
      ba = build(:korea_bank_account, bank_code: "NACFKRSEXX")
      ba.save!(validate: false)

      expect(ba.mark_deleted!).to be_truthy
      expect(ba.reload).to be_deleted
    end

    it "still rejects a code the save is changing" do
      ba = build(:korea_bank_account, bank_code: "NACFKRSE")
      ba.save!(validate: false)

      ba.bank_code = "NACFKRSEXX"
      expect(ba).not_to be_valid
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      expect(build(:korea_bank_account, account_number: "00123456789")).to be_valid
      expect(build(:korea_bank_account, account_number: "0000123456789")).to be_valid
      expect(build(:korea_bank_account, account_number: "000000123456789")).to be_valid
      expect(build(:korea_bank_account, account_number: "1234567890123456")).to be_valid

      kr_bank_account = build(:korea_bank_account, account_number: "12345678901234567")
      expect(kr_bank_account).to_not be_valid
      expect(kr_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      kr_bank_account = build(:korea_bank_account, account_number: "ABCDEFGHIJKL")
      expect(kr_bank_account).to_not be_valid
      expect(kr_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      kr_bank_account = build(:korea_bank_account, account_number: "8937040044053201300000")
      expect(kr_bank_account).to_not be_valid
      expect(kr_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      kr_bank_account = build(:korea_bank_account, account_number: "12345")
      expect(kr_bank_account).to_not be_valid
      expect(kr_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
