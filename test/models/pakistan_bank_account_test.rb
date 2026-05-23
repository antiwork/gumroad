# frozen_string_literal: true

require "test_helper"

class PakistanBankAccountTest < ActiveSupport::TestCase
  self.described_class = PakistanBankAccount



  context_ PakistanBankAccount do
  context_ "#bank_account_type" do
  test "returns Pakistan" do
        expect(create(:pakistan_bank_account).bank_account_type).to eq("PK")
      end
    end

  context_ "#country" do
  test "returns PK" do
        expect(create(:pakistan_bank_account).country).to eq("PK")
      end
    end

  context_ "#currency" do
  test "returns pkr" do
        expect(create(:pakistan_bank_account).currency).to eq("pkr")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 11 characters" do
        ba = create(:pakistan_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("AAAAPKKAXXX")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:pakistan_bank_account, account_number_last_four: "6702").account_number_visual).to eq("******6702")
      end
    end

  context_ "#validate_bank_code" do
  test "allows 8 to 11 characters only" do
        expect(build(:pakistan_bank_account, bank_code: "AAAAPKKAXXX")).to be_valid
        expect(build(:pakistan_bank_account, bank_code: "AAAAPKKA")).to be_valid
        expect(build(:pakistan_bank_account, bank_code: "AAAAPKK")).not_to be_valid
        expect(build(:pakistan_bank_account, bank_code: "AAAAPKKAXXXX")).not_to be_valid
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        allow(Rails.env).to receive(:production?).and_return(true)

        expect(build(:pakistan_bank_account)).to be_valid
        expect(build(:pakistan_bank_account, account_number: "PK36SCBL0000001123456702")).to be_valid

        pk_bank_account = build(:pakistan_bank_account, account_number: "PK12345")
        expect(pk_bank_account).not_to be_valid
        expect(pk_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        pk_bank_account = build(:pakistan_bank_account, account_number: "PK36SCBL00000011234567021")
        expect(pk_bank_account).not_to be_valid
        expect(pk_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        pk_bank_account = build(:pakistan_bank_account, account_number: "PK36SCBL000000112345670")
        expect(pk_bank_account).not_to be_valid
        expect(pk_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        pk_bank_account = build(:pakistan_bank_account, account_number: "PKABCDE")
        expect(pk_bank_account).not_to be_valid
        expect(pk_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
