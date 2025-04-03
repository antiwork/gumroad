# frozen_string_literal: true

describe LaosBankAccount do
  describe "#bank_account_type" do
    it "returns LA" do
      expect(create(:laos_bank_account).bank_account_type).to eq("LA")
    end
  end

  describe "#country" do
    it "returns LA" do
      expect(create(:laos_bank_account).country).to eq("LA")
    end
  end

  describe "#currency" do
    it "returns lak" do
      expect(create(:laos_bank_account).currency).to eq("lak")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:laos_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAALALAXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:laos_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      expect(build(:laos_bank_account)).to be_valid
      expect(build(:laos_bank_account, account_number: "000123456789")).to be_valid
      expect(build(:laos_bank_account, account_number: "0")).to be_valid
      expect(build(:laos_bank_account, account_number: "000012345678910111")).to be_valid

      la_bank_account = build(:laos_bank_account, account_number: "0000123456789101111")
      expect(la_bank_account).to_not be_valid
      expect(la_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
