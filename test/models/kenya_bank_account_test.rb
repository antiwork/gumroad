# frozen_string_literal: true

require "test_helper"

class KenyaBankAccountTest < ActiveSupport::TestCase
  self.described_class = KenyaBankAccount



  context_ KenyaBankAccount do
  context_ "#bank_account_type" do
  test "returns KE" do
        expect(create(:kenya_bank_account).bank_account_type).to eq("KE")
      end
    end

  context_ "#country" do
  test "returns KE" do
        expect(create(:kenya_bank_account).country).to eq("KE")
      end
    end

  context_ "#currency" do
  test "returns kes" do
        expect(create(:kenya_bank_account).currency).to eq("kes")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 11 characters" do
        ba = create(:kenya_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("BARCKENXMDR")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:kenya_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
      end
    end

  context_ "#validate_bank_code" do
  test "allows 8 to 11 characters only" do
        expect(build(:kenya_bank_account, bank_code: "BARCKENX")).to be_valid
        expect(build(:kenya_bank_account, bank_code: "BARCKENXMDR")).to be_valid
        expect(build(:kenya_bank_account, bank_code: "BARCKEN")).not_to be_valid
        expect(build(:kenya_bank_account, bank_code: "BARCKENXMDRX")).not_to be_valid
      end
    end
  end
end
