# frozen_string_literal: true

require "test_helper"

class IndianBankAccountTest < ActiveSupport::TestCase
  self.described_class = IndianBankAccount



  context_ IndianBankAccount do
  context_ "#bank_account_type" do
  test "returns Indian" do
        expect(create(:indian_bank_account).bank_account_type).to eq("IN")
      end
    end

  context_ "#country" do
  test "returns IN" do
        expect(create(:indian_bank_account).country).to eq("IN")
      end
    end

  context_ "#currency" do
  test "returns inr" do
        expect(create(:indian_bank_account).currency).to eq("inr")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 11 characters" do
        ba = create(:indian_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("HDFC0004051")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:indian_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
      end
    end

  context_ "#validate_ifsc" do
  test "allows 11 characters only" do
        expect(build(:indian_bank_account, ifsc: "HDFC0004051")).to be_valid
        expect(build(:indian_bank_account, ifsc: "ICIC0123456")).to be_valid
        expect(build(:indian_bank_account, ifsc: "HDFC00040511")).not_to be_valid
        expect(build(:indian_bank_account, ifsc: "HDFC000405")).not_to be_valid
      end
    end
  end
end
