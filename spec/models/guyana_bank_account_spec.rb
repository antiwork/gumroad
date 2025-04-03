# frozen_string_literal: true

describe GuyanaBankAccount do
  describe "#bank_account_type" do
    it "returns GY" do
      expect(create(:guyana_bank_account).bank_account_type).to eq("GY")
    end
  end

  describe "#country" do
    it "returns GY" do
      expect(create(:guyana_bank_account).country).to eq("GY")
    end
  end

  describe "#currency" do
    it "returns gyd" do
      expect(create(:guyana_bank_account).currency).to eq("gyd")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:guyana_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAAGYGGXYZ")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:guyana_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      expect(build(:guyana_bank_account)).to be_valid
      expect(build(:guyana_bank_account, account_number: "00012345678910111213141516171819")).to be_valid
      expect(build(:guyana_bank_account, account_number: "1")).to be_valid
      expect(build(:guyana_bank_account, account_number: "GUY12345678910111213141516171819")).to be_valid

      gy_bank_account = build(:guyana_bank_account, account_number: "0001234567891011121314151617181920")
      expect(gy_bank_account).to_not be_valid
      expect(gy_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      gy_bank_account = build(:guyana_bank_account, account_number: "GUY1234567891011121314151617181920")
      expect(gy_bank_account).to_not be_valid
      expect(gy_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
