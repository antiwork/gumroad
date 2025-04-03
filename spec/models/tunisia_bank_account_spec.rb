# frozen_string_literal: true

describe TunisiaBankAccount do
  describe "#bank_account_type" do
    it "returns Tunisia" do
      expect(create(:tunisia_bank_account).bank_account_type).to eq("TN")
    end
  end

  describe "#country" do
    it "returns TN" do
      expect(create(:tunisia_bank_account).country).to eq("TN")
    end
  end

  describe "#currency" do
    it "returns tnd" do
      expect(create(:tunisia_bank_account).currency).to eq("tnd")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:tunisia_bank_account, account_number_last_four: "2345").account_number_visual).to eq("TN******2345")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(build(:tunisia_bank_account)).to be_valid
      expect(build(:tunisia_bank_account, account_number: "TN 5904 0181 0400 4942 7123 45")).to be_valid

      tn_bank_account = build(:tunisia_bank_account, account_number: "TN12345")
      expect(tn_bank_account).to_not be_valid
      expect(tn_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      tn_bank_account = build(:tunisia_bank_account, account_number: "DE61109010140000071219812874")
      expect(tn_bank_account).to_not be_valid
      expect(tn_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      tn_bank_account = build(:tunisia_bank_account, account_number: "8937040044053201300000")
      expect(tn_bank_account).to_not be_valid
      expect(tn_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      tn_bank_account = build(:tunisia_bank_account, account_number: "TNABCDE")
      expect(tn_bank_account).to_not be_valid
      expect(tn_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
