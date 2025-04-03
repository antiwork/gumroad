# frozen_string_literal: true

describe SerbiaBankAccount do
  describe "#bank_account_type" do
    it "returns Serbia" do
      expect(create(:serbia_bank_account).bank_account_type).to eq("RS")
    end
  end

  describe "#country" do
    it "returns RS" do
      expect(create(:serbia_bank_account).country).to eq("RS")
    end
  end

  describe "#currency" do
    it "returns rsd" do
      expect(create(:serbia_bank_account).currency).to eq("rsd")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:serbia_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("TESTSERBXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:serbia_bank_account, account_number_last_four: "9123").account_number_visual).to eq("RS******9123")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(build(:serbia_bank_account)).to be_valid
      expect(build(:serbia_bank_account, account_number: "RS35105008123123123173")).to be_valid

      rs_bank_account = build(:serbia_bank_account, account_number: "MA12345")
      expect(rs_bank_account).to_not be_valid
      expect(rs_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      rs_bank_account = build(:serbia_bank_account, account_number: "DE61109010140000071219812874")
      expect(rs_bank_account).to_not be_valid
      expect(rs_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      rs_bank_account = build(:serbia_bank_account, account_number: "89370400044053201300000")
      expect(rs_bank_account).to_not be_valid
      expect(rs_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      rs_bank_account = build(:serbia_bank_account, account_number: "CRABCDE")
      expect(rs_bank_account).to_not be_valid
      expect(rs_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
