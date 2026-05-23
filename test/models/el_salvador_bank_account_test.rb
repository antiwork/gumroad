# frozen_string_literal: true

require "test_helper"

class ElSalvadorBankAccountTest < ActiveSupport::TestCase
  self.described_class = ElSalvadorBankAccount



  context_ ElSalvadorBankAccount do
  context_ "#bank_account_type" do
  test "returns SV" do
        expect(create(:el_salvador_bank_account).bank_account_type).to eq("SV")
      end
    end

  context_ "#country" do
  test "returns SV" do
        expect(create(:el_salvador_bank_account).country).to eq("SV")
      end
    end

  context_ "#currency" do
  test "returns usd" do
        expect(create(:el_salvador_bank_account).currency).to eq("usd")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 11 characters" do
        ba = create(:el_salvador_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("AAAASVS1XXX")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:el_salvador_bank_account, account_number_last_four: "7890").account_number_visual).to eq("******7890")
      end
    end

  context_ "#validate_bank_code" do
  test "allows 8 to 11 characters only" do
        expect(build(:el_salvador_bank_account, bank_code: "AAAASVS1")).to be_valid
        expect(build(:el_salvador_bank_account, bank_code: "AAAASVS1XXX")).to be_valid
        expect(build(:el_salvador_bank_account, bank_code: "AAAASV")).not_to be_valid
        expect(build(:el_salvador_bank_account, bank_code: "AAAASVS1XXXX")).not_to be_valid
      end
    end

  context_ "#validate_account_number" do
  test "accepts plain account numbers (10-20 digits)" do
        expect(build(:el_salvador_bank_account, account_number: "1234567890")).to be_valid
        expect(build(:el_salvador_bank_account, account_number: "12345678901234567890")).to be_valid
      end

  test "accepts valid SV IBAN format (28 chars)" do
        expect(build(:el_salvador_bank_account, account_number: "SV44BCIE12345678901234567890")).to be_valid
        expect(build(:el_salvador_bank_account, account_number: "SV88CAGR00000000003280602160")).to be_valid
      end

  test "rejects invalid formats" do
        expect(build(:el_salvador_bank_account, account_number: "123456789")).not_to be_valid
        expect(build(:el_salvador_bank_account, account_number: "123456789012345678901")).not_to be_valid
        expect(build(:el_salvador_bank_account, account_number: "12345ABC90")).not_to be_valid
        expect(build(:el_salvador_bank_account, account_number: "SV99BCIE12345678901234567890")).not_to be_valid
      end
    end

  context_ ".build_iban" do
  test "constructs the IBAN from a SWIFT/BIC and a plain account number" do
        expect(described_class.build_iban("CAGRSVSS", "3280602160")).to eq("SV88CAGR00000000003280602160")
        expect(described_class.build_iban("BCIESVS1", "12345678901234567890")).to eq("SV44BCIE12345678901234567890")
        expect(described_class.build_iban("AAAASVS1XXX", "12345678901234")).to eq("SV12AAAA00000012345678901234")
      end

  test "uppercases the bank code" do
        expect(described_class.build_iban("cagrsvss", "3280602160")).to eq("SV88CAGR00000000003280602160")
      end

  test "produces an IBAN that passes Ibandit structural validation" do
        iban = described_class.build_iban("CAGRSVSS", "3280602160")
        expect(Ibandit::IBAN.new(iban).valid?).to be(true)
      end
    end

  context_ "#stripe_account_number" do
      let(:passphrase) { GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD") }

  test "constructs an IBAN when a plain account number is stored" do
        ba = create(:el_salvador_bank_account, account_number: "3280602160", bank_number: "CAGRSVSS", account_number_last_four: "2160")
        expect(ba.stripe_account_number(passphrase)).to eq("SV88CAGR00000000003280602160")
      end

  test "passes through a stored IBAN unchanged" do
        ba = create(:el_salvador_bank_account, account_number: "SV88CAGR00000000003280602160", bank_number: "CAGRSVSS", account_number_last_four: "2160")
        expect(ba.stripe_account_number(passphrase)).to eq("SV88CAGR00000000003280602160")
      end
    end
  end
end
