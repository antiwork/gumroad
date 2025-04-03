# frozen_string_literal: true

describe ChileBankAccount do
  describe "#bank_account_type" do
    it "returns Chile" do
      expect(create(:chile_bank_account).bank_account_type).to eq("CL")
    end
  end

  describe "#country" do
    it "returns CL" do
      expect(create(:chile_bank_account).country).to eq("CL")
    end
  end

  describe "#currency" do
    it "returns clp" do
      expect(create(:chile_bank_account).currency).to eq("clp")
    end
  end

  describe "#routing_number" do
    it "returns valid for 3 characters" do
      ba = create(:chile_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("999")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:chile_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
    end
  end

  describe "#validate_bank_code" do
    it "allows 3 numeric characters only" do
      expect(build(:chile_bank_account, bank_code: "123")).to be_valid
      expect(build(:chile_bank_account, bank_code: "12")).not_to be_valid
      expect(build(:chile_bank_account, bank_code: "1234")).not_to be_valid
      expect(build(:chile_bank_account, bank_code: "12A")).not_to be_valid
      expect(build(:chile_bank_account, bank_code: "12@")).not_to be_valid
    end
  end

  describe "account types" do
    it "allows checking account types" do
      chile_bank_account = build(:chile_bank_account, account_type: ChileBankAccount::AccountType::CHECKING)
      expect(chile_bank_account).to be_valid
      expect(chile_bank_account.account_type).to eq(ChileBankAccount::AccountType::CHECKING)
    end

    it "allows savings account types" do
      chile_bank_account = build(:chile_bank_account, account_type: ChileBankAccount::AccountType::SAVINGS)
      expect(chile_bank_account).to be_valid
      expect(chile_bank_account.account_type).to eq(ChileBankAccount::AccountType::SAVINGS)
    end

    it "invalidates other account types" do
      chile_bank_account = build(:chile_bank_account, account_type: "evil_account_type")
      expect(chile_bank_account).to_not be_valid
    end

    it "translates a nil account type to the default (checking)" do
      chile_bank_account = build(:chile_bank_account, account_type: nil)
      expect(chile_bank_account).to be_valid
      expect(chile_bank_account.account_type).to eq(ChileBankAccount::AccountType::CHECKING)
    end
  end
end
