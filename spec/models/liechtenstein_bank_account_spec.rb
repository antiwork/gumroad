# frozen_string_literal: true

require "spec_helper"

describe LiechtensteinBankAccount do
  describe "#bank_account_type" do
    it "returns LI" do
      expect(create(:liechtenstein_bank_account).bank_account_type).to eq("LI")
    end
  end

  describe "#country" do
    it "returns LI" do
      expect(create(:liechtenstein_bank_account).country).to eq("LI")
    end
  end

  describe "#currency" do
    it "returns chf" do
      expect(create(:liechtenstein_bank_account).currency).to eq("chf")
    end
  end

  describe "#routing_number" do
    it "returns nil" do
      expect(create(:liechtenstein_bank_account).routing_number).to be nil
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number with country code prefixed" do
      expect(create(:liechtenstein_bank_account, account_number_last_four: "8777").account_number_visual).to eq("******8777")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(build(:liechtenstein_bank_account)).to be_valid
      expect(build(:liechtenstein_bank_account, account_number: "LI0508800636123378777")).to be_valid

      li_bank_account = build(:liechtenstein_bank_account, account_number: "LI938601111")
      expect(li_bank_account).to_not be_valid
      expect(li_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      li_bank_account = build(:liechtenstein_bank_account, account_number: "LIABCDEFGHIJKLM")
      expect(li_bank_account).to_not be_valid
      expect(li_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      li_bank_account = build(:liechtenstein_bank_account, account_number: "LI9386011117947123456")
      expect(li_bank_account).to_not be_valid
      expect(li_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      li_bank_account = build(:liechtenstein_bank_account, account_number: "129386011117947")
      expect(li_bank_account).to_not be_valid
      expect(li_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
