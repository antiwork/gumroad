# frozen_string_literal: true

require "test_helper"

class IndonesiaBankAccountTest < ActiveSupport::TestCase
  self.described_class = IndonesiaBankAccount


  context_ IndonesiaBankAccount do
  context_ "#bank_account_type" do
  test "returns Indonesia" do
        expect(create(:indonesia_bank_account).bank_account_type).to eq("ID")
      end
    end

  context_ "#country" do
  test "returns ID" do
        expect(create(:indonesia_bank_account).country).to eq("ID")
      end
    end

  context_ "#currency" do
  test "returns idr" do
        expect(create(:indonesia_bank_account).currency).to eq("idr")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 4 characters" do
        ba = create(:indonesia_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("000")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:indonesia_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
      end
    end

  context_ "#validate_bank_code" do
  test "allows 3 to 4 alphanumeric characters only" do
        expect(build(:indonesia_bank_account, bank_code: "123")).to be_valid
        expect(build(:indonesia_bank_account, bank_code: "1234")).to be_valid
        expect(build(:indonesia_bank_account, bank_code: "12AB")).to be_valid
        expect(build(:indonesia_bank_account, bank_code: "12")).not_to be_valid
        expect(build(:indonesia_bank_account, bank_code: "12345")).not_to be_valid
        expect(build(:indonesia_bank_account, bank_code: "12@#")).not_to be_valid
      end
    end
  end
end
