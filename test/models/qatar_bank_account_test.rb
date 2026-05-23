# frozen_string_literal: true

require "test_helper"

class QatarBankAccountTest < ActiveSupport::TestCase
  self.described_class = QatarBankAccount



  context_ QatarBankAccount do
  context_ "#bank_account_type" do
  test "returns QA" do
        expect(create(:qatar_bank_account).bank_account_type).to eq("QA")
      end
    end

  context_ "#country" do
  test "returns QA" do
        expect(create(:qatar_bank_account).country).to eq("QA")
      end
    end

  context_ "#currency" do
  test "returns qar" do
        expect(create(:qatar_bank_account).currency).to eq("qar")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 11 characters" do
        ba = create(:qatar_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("AAAAQAQAXXX")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:qatar_bank_account, account_number_last_four: "8901").account_number_visual).to eq("******8901")
      end
    end

  context_ "#validate_bank_code" do
  test "allows 11 characters only" do
        expect(build(:qatar_bank_account, bank_code: "AAAAQAQAXXX")).to be_valid
        expect(build(:qatar_bank_account, bank_code: "AAAAQAQA")).not_to be_valid
        expect(build(:qatar_bank_account, bank_code: "AAAAQAQAXXXX")).not_to be_valid
      end
    end
  end
end
