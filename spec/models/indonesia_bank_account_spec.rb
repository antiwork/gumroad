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
    it "returns the 3-digit bank code" do
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
    it "allows exactly 3 digits" do
      expect(build(:indonesia_bank_account, bank_code: "014")).to be_valid
      expect(build(:indonesia_bank_account, bank_code: "008")).to be_valid
    end

    it "rejects the shapes Stripe's ID directory refuses" do
      expect(build(:indonesia_bank_account, bank_code: "BBSB")).not_to be_valid
      expect(build(:indonesia_bank_account, bank_code: "BCA")).not_to be_valid
      expect(build(:indonesia_bank_account, bank_code: "0140")).not_to be_valid
      expect(build(:indonesia_bank_account, bank_code: "12")).not_to be_valid
      expect(build(:indonesia_bank_account, bank_code: "12345")).not_to be_valid
      expect(build(:indonesia_bank_account, bank_code: "12@#")).not_to be_valid
    end

    it "names the expected format in the error" do
      ba = build(:indonesia_bank_account, bank_code: "BBSB")
      ba.valid?
      expect(ba.errors.full_messages).to include("Enter your bank's 3-digit Indonesian bank code, digits only.")
    end

    it "does not re-validate a pre-existing bad code on an unrelated save" do
      ba = build(:indonesia_bank_account, bank_code: "BBSB")
      ba.save!(validate: false)

      expect(ba.mark_deleted!).to be_truthy
      expect(ba.reload).to be_deleted
    end

    it "still rejects a bad code when the code itself is being changed" do
      ba = build(:indonesia_bank_account, bank_code: "BBSB")
      ba.save!(validate: false)

      ba.bank_code = "CENA"
      expect(ba).not_to be_valid
    end
  end
end
