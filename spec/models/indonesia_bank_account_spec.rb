# frozen_string_literal: true

describe IndonesiaBankAccount do
  describe "#bank_account_type" do
    it "returns Indonesia" do
      expect(create(:indonesia_bank_account).bank_account_type).to eq("ID")
    end
  end

  describe "#country" do
    it "returns ID" do
      expect(create(:indonesia_bank_account).country).to eq("ID")
    end
  end

  describe "#currency" do
    it "returns idr" do
      expect(create(:indonesia_bank_account).currency).to eq("idr")
    end
  end

  describe "#routing_number" do
    it "returns valid for 4 characters" do
      ba = create(:indonesia_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("000")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:indonesia_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
    end
  end

  describe "#validate_bank_code" do
    it "allows 3 to 4 alphanumeric characters only" do
      expect(build(:indonesia_bank_account, bank_code: "123")).to be_valid
      expect(build(:indonesia_bank_account, bank_code: "1234")).to be_valid
      expect(build(:indonesia_bank_account, bank_code: "12AB")).to be_valid
      expect(build(:indonesia_bank_account, bank_code: "12")).not_to be_valid
      expect(build(:indonesia_bank_account, bank_code: "12345")).not_to be_valid
      expect(build(:indonesia_bank_account, bank_code: "12@#")).not_to be_valid
    end
  end
end
