# frozen_string_literal: true

describe BhutanBankAccount do
  describe "#bank_account_type" do
    it "returns BT" do
      expect(create(:bhutan_bank_account).bank_account_type).to eq("BT")
    end
  end

  describe "#country" do
    it "returns BT" do
      expect(create(:bhutan_bank_account).country).to eq("BT")
    end
  end

  describe "#currency" do
    it "returns btn" do
      expect(create(:bhutan_bank_account).currency).to eq("btn")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:bhutan_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAABTBTXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:bhutan_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      expect(build(:bhutan_bank_account)).to be_valid
      expect(build(:bhutan_bank_account, account_number: "0000123456789")).to be_valid
      expect(build(:bhutan_bank_account, account_number: "0")).to be_valid
      expect(build(:bhutan_bank_account, account_number: "00001234567891011")).to be_valid

      bt_bank_account = build(:bhutan_bank_account, account_number: "0000123456789101112")
      expect(bt_bank_account).to_not be_valid
      expect(bt_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
