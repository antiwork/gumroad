# frozen_string_literal: true

require "spec_helper"

describe ElSalvadorBankAccount do
  describe "#bank_account_type" do
    it "returns SV" do
      expect(create(:el_salvador_bank_account).bank_account_type).to eq("SV")
    end
  end

  describe "#country" do
    it "returns SV" do
      expect(create(:el_salvador_bank_account).country).to eq("SV")
    end
  end

  describe "#currency" do
    it "returns usd" do
      expect(create(:el_salvador_bank_account).currency).to eq("usd")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:el_salvador_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAASVS1XXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:el_salvador_bank_account, account_number_last_four: "7890").account_number_visual).to eq("******7890")
    end
  end

  describe "#validate_bank_code" do
    it "allows 8 to 11 characters only" do
      expect(build(:el_salvador_bank_account, bank_code: "AAAASVS1")).to be_valid
      expect(build(:el_salvador_bank_account, bank_code: "AAAASVS1XXX")).to be_valid
      expect(build(:el_salvador_bank_account, bank_code: "AAAASV")).not_to be_valid
      expect(build(:el_salvador_bank_account, bank_code: "AAAASVS1XXXX")).not_to be_valid
    end
  end

  describe "#validate_account_number" do
    it "accepts plain account numbers (10-20 digits)" do
      expect(build(:el_salvador_bank_account, account_number: "1234567890")).to be_valid
      expect(build(:el_salvador_bank_account, account_number: "12345678901234567890")).to be_valid
    end

    it "accepts valid SV IBAN format (28 chars)" do
      expect(build(:el_salvador_bank_account, account_number: "SV44BCIE12345678901234567890")).to be_valid
      expect(build(:el_salvador_bank_account, account_number: "SV88CAGR00000000003280602160")).to be_valid
    end

    it "rejects invalid formats" do
      expect(build(:el_salvador_bank_account, account_number: "123456789")).not_to be_valid
      expect(build(:el_salvador_bank_account, account_number: "123456789012345678901")).not_to be_valid
      expect(build(:el_salvador_bank_account, account_number: "12345ABC90")).not_to be_valid
      expect(build(:el_salvador_bank_account, account_number: "SV99BCIE12345678901234567890")).not_to be_valid
    end
  end

  describe ".build_iban" do
    it "constructs the IBAN from a SWIFT/BIC and a plain account number" do
      expect(described_class.build_iban("CAGRSVSS", "3280602160")).to eq("SV88CAGR00000000003280602160")
      expect(described_class.build_iban("BCIESVS1", "12345678901234567890")).to eq("SV44BCIE12345678901234567890")
      expect(described_class.build_iban("AAAASVS1XXX", "12345678901234")).to eq("SV12AAAA00000012345678901234")
    end

    it "uppercases the bank code" do
      expect(described_class.build_iban("cagrsvss", "3280602160")).to eq("SV88CAGR00000000003280602160")
    end

    it "produces an IBAN that passes Ibandit structural validation" do
      iban = described_class.build_iban("CAGRSVSS", "3280602160")
      expect(Ibandit::IBAN.new(iban).valid?).to be(true)
    end
  end

  describe "#stripe_account_number" do
    let(:passphrase) { GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD") }

    it "constructs an IBAN when a plain account number is stored" do
      ba = create(:el_salvador_bank_account, account_number: "3280602160", bank_number: "CAGRSVSS", account_number_last_four: "2160")
      expect(ba.stripe_account_number(passphrase)).to eq("SV88CAGR00000000003280602160")
    end

    it "passes through a stored IBAN unchanged" do
      ba = create(:el_salvador_bank_account, account_number: "SV88CAGR00000000003280602160", bank_number: "CAGRSVSS", account_number_last_four: "2160")
      expect(ba.stripe_account_number(passphrase)).to eq("SV88CAGR00000000003280602160")
    end
  end
end
