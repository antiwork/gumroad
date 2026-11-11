# frozen_string_literal: true

require "spec_helper"

describe CanadianBankAccount do
  describe "transit_number" do
    describe "is 5 digits" do
      let(:canadian_bank_account) { build(:canadian_bank_account, transit_number: "12345") }

      it "is valid" do
        expect(canadian_bank_account).to be_valid
      end
    end

    describe "nil" do
      let(:canadian_bank_account) { build(:canadian_bank_account, transit_number: nil) }

      it "is not valid" do
        expect(canadian_bank_account).not_to be_valid
      end
    end

    describe "is 4 digits" do
      let(:canadian_bank_account) { build(:canadian_bank_account, transit_number: "1234") }

      it "is not valid" do
        expect(canadian_bank_account).not_to be_valid
      end
    end

    describe "is 6 digits" do
      let(:canadian_bank_account) { build(:canadian_bank_account, transit_number: "123456") }

      it "is not valid" do
        expect(canadian_bank_account).not_to be_valid
      end
    end

    describe "contains alpha characters" do
      let(:canadian_bank_account) { build(:canadian_bank_account, transit_number: "1234a") }

      it "is not valid" do
        expect(canadian_bank_account).not_to be_valid
      end
    end
  end

  describe "institution_number" do
    describe "is 3 digits" do
      let(:canadian_bank_account) { build(:canadian_bank_account, institution_number: "123") }

      it "is valid" do
        expect(canadian_bank_account).to be_valid
      end
    end

    describe "nil" do
      let(:canadian_bank_account) { build(:canadian_bank_account, institution_number: nil) }

      it "is not valid" do
        expect(canadian_bank_account).not_to be_valid
      end
    end

    describe "is 2 digits" do
      let(:canadian_bank_account) { build(:canadian_bank_account, institution_number: "12") }

      it "is not valid" do
        expect(canadian_bank_account).not_to be_valid
      end
    end

    describe "is 4 digits" do
      let(:canadian_bank_account) { build(:canadian_bank_account, institution_number: "1234") }

      it "is not valid" do
        expect(canadian_bank_account).not_to be_valid
      end
    end

    describe "contains alpha characters" do
      let(:canadian_bank_account) { build(:canadian_bank_account, institution_number: "12a") }

      it "is not valid" do
        expect(canadian_bank_account).not_to be_valid
      end
    end
  end

  describe "routing_number" do
    let(:canadian_bank_account) { build(:canadian_bank_account, transit_number: "45678", institution_number: "123") }

    it "is a concat of institution_number, hyphen and transit_number" do
      expect(canadian_bank_account.routing_number).to eq("45678-123")
    end
  end

  describe "#validate_account_number" do
    it "accepts 1 to 12 digits" do
      %w[1 12 1234567 123456789012].each do |number|
        expect(build(:canadian_bank_account, account_number: number)).to be_valid, "expected #{number.length} digits to be valid"
      end
    end

    it "rejects blank" do
      expect(build(:canadian_bank_account, account_number: "")).not_to be_valid
    end

    it "rejects more than 12 digits and letters" do
      ["1234567890123", "1234567890123456", "12345678A"].each do |number|
        account = build(:canadian_bank_account, account_number: number)
        expect(account).not_to be_valid, "expected #{number.inspect} to be invalid"
        expect(account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end

    describe "existing rows with a number that no longer conforms" do
      let(:account) do
        build(:canadian_bank_account, account_number: "1234567890123456").tap { |a| a.save!(validate: false) }
      end

      it "does not block unrelated saves or deletion" do
        account = BankAccount.find(self.account.id)
        expect(account.update(account_holder_full_name: "New Name")).to be(true)
        expect { account.mark_deleted! }.not_to raise_error
      end

      it "rejects reassigning the number to a non-conforming value" do
        account = BankAccount.find(self.account.id)
        account.account_number = "6543210987654321"
        expect(account).not_to be_valid
      end

      it "treats re-assigning the identical plaintext as a change" do
        account = BankAccount.find(self.account.id)
        account.account_number = "1234567890123456"
        expect(account).not_to be_valid
      end
    end
  end
end
