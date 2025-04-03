# frozen_string_literal: true

describe BangladeshBankAccount do
  describe "#bank_account_type" do
    it "returns BD" do
      expect(create(:bangladesh_bank_account).bank_account_type).to eq("BD")
    end
  end

  describe "#country" do
    it "returns BD" do
      expect(create(:bangladesh_bank_account).country).to eq("BD")
    end
  end

  describe "#currency" do
    it "returns bdt" do
      expect(create(:bangladesh_bank_account).currency).to eq("bdt")
    end
  end

  describe "#routing_number" do
    it "returns valid for 9 characters" do
      ba = create(:bangladesh_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("110000000")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:bangladesh_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      expect(build(:bangladesh_bank_account)).to be_valid
      expect(build(:bangladesh_bank_account, account_number: "0000123456789")).to be_valid
      expect(build(:bangladesh_bank_account, account_number: "00001234567891011")).to be_valid

      bd_bank_account = build(:bangladesh_bank_account, account_number: "000012345678")
      expect(bd_bank_account).to_not be_valid
      expect(bd_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      bd_bank_account = build(:bangladesh_bank_account, account_number: "0000123456789101112")
      expect(bd_bank_account).to_not be_valid
      expect(bd_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      bd_bank_account = build(:bangladesh_bank_account, account_number: "BD00123456789101112")
      expect(bd_bank_account).to_not be_valid
      expect(bd_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      bd_bank_account = build(:bangladesh_bank_account, account_number: "BDABC")
      expect(bd_bank_account).to_not be_valid
      expect(bd_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
