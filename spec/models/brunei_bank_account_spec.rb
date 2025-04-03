# frozen_string_literal: true

describe BruneiBankAccount do
  describe "#bank_account_type" do
    it "returns BN" do
      expect(create(:brunei_bank_account).bank_account_type).to eq("BN")
    end
  end

  describe "#country" do
    it "returns BN" do
      expect(create(:brunei_bank_account).country).to eq("BN")
    end
  end

  describe "#currency" do
    it "returns bnd" do
      expect(create(:brunei_bank_account).currency).to eq("bnd")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:brunei_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAABNBBXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:brunei_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      expect(build(:brunei_bank_account)).to be_valid
      expect(build(:brunei_bank_account, account_number: "000012345")).to be_valid
      expect(build(:brunei_bank_account, account_number: "1")).to be_valid
      expect(build(:brunei_bank_account, account_number: "000012345678")).to be_valid

      bn_bank_account = build(:brunei_bank_account, account_number: "000012345678910")
      expect(bn_bank_account).to_not be_valid
      expect(bn_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      bn_bank_account = build(:brunei_bank_account, account_number: "BN0012345678910")
      expect(bn_bank_account).to_not be_valid
      expect(bn_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
