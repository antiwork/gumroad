# frozen_string_literal: true

describe NorthMacedoniaBankAccount do
  describe "#bank_account_type" do
    it "returns Macedonia" do
      expect(create(:north_macedonia_bank_account).bank_account_type).to eq("MK")
    end
  end

  describe "#country" do
    it "returns MK" do
      expect(create(:north_macedonia_bank_account).country).to eq("MK")
    end
  end

  describe "#currency" do
    it "returns mkd" do
      expect(create(:north_macedonia_bank_account).currency).to eq("mkd")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:north_macedonia_bank_account, account_number_last_four: "2345").account_number_visual).to eq("MK******2345")
    end
  end

  describe "#validate_bank_code" do
    it "allows records that match the required bank code format" do
      expect(build(:north_macedonia_bank_account, bank_code: "AAAAMK2XXXX")).to be_valid
      expect(build(:north_macedonia_bank_account, bank_code: "AAAAMK2X")).to be_valid

      mk_bank_account = build(:north_macedonia_bank_account, bank_code: "AAAAMK2XXXXX")
      expect(mk_bank_account).not_to be_valid
      expect(mk_bank_account.errors[:base]).to include("The bank code is invalid.")

      mk_bank_account = build(:north_macedonia_bank_account, bank_code: "AAAA2MK")
      expect(mk_bank_account).not_to be_valid
      expect(mk_bank_account.errors[:base]).to include("The bank code is invalid.")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(build(:north_macedonia_bank_account)).to be_valid
      expect(build(:north_macedonia_bank_account, account_number: "MK07250120000058984")).to be_valid
      expect(build(:north_macedonia_bank_account, account_number: "ABC7250120000058984")).to be_valid
      expect(build(:north_macedonia_bank_account, account_number: "0007250120000058984")).to be_valid
      expect(build(:north_macedonia_bank_account, account_number: "ABCDEFGHIJKLMNOPQRS")).to be_valid

      mk_bank_account = build(:north_macedonia_bank_account, account_number: "MK0725012000005898")
      expect(mk_bank_account).to_not be_valid
      expect(mk_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      mk_bank_account = build(:north_macedonia_bank_account, account_number: "MK072501200000589845")
      expect(mk_bank_account).to_not be_valid
      expect(mk_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      mk_bank_account = build(:north_macedonia_bank_account, account_number: "00072501200000589845")
      expect(mk_bank_account).to_not be_valid
      expect(mk_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      mk_bank_account = build(:north_macedonia_bank_account, account_number: "ABCDEFGHIJKLMNOPQR")
      expect(mk_bank_account).to_not be_valid
      expect(mk_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end

  describe "#routing_number" do
    it "returns the bank code" do
      bank_account = create(:north_macedonia_bank_account, bank_code: "AAAAMK2XXXX")
      expect(bank_account.routing_number).to eq("AAAAMK2XXXX")
    end
  end

  describe "#to_hash" do
    it "returns hash with bank account details" do
      bank_account = create(:north_macedonia_bank_account,
                            bank_code: "AAAAMK2XXXX",
                            account_number_last_four: "8907"
      )

      expect(bank_account.to_hash).to eq(
        routing_number: "AAAAMK2XXXX",
        account_number: "MK******8907",
        bank_account_type: "MK"
      )
    end
  end
end
