# frozen_string_literal: true

require "test_helper"

class SingaporeanBankAccountTest < ActiveSupport::TestCase
  self.described_class = SingaporeanBankAccount



  context_ SingaporeanBankAccount do
  context_ "#bank_account_type" do
  test "returns singapore" do
        expect(create(:singaporean_bank_account).bank_account_type).to eq("SG")
      end
    end

  context_ "#country" do
  test "returns SG" do
        expect(create(:singaporean_bank_account).country).to eq("SG")
      end
    end

  context_ "#currency" do
  test "returns sgd" do
        expect(create(:singaporean_bank_account).currency).to eq("sgd")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 7 digits with hyphen after 4" do
        ba = create(:singaporean_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("1100-000")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:singaporean_bank_account, account_number_last_four: "3456").account_number_visual).to eq("******3456")
      end
    end

  context_ "#validate_bank_code" do
  test "allows 4 digits only" do
        expect(build(:singaporean_bank_account, bank_code: "1100")).to be_valid
        expect(build(:singaporean_bank_account, bank_code: "1234")).to be_valid
        expect(build(:singaporean_bank_account, bank_code: "110")).not_to be_valid
        expect(build(:singaporean_bank_account, bank_code: "ABCD")).not_to be_valid
      end
    end

  context_ "#validate_branch_code" do
  test "allows 3 digits only" do
        expect(build(:singaporean_bank_account, branch_code: "110")).to be_valid
        expect(build(:singaporean_bank_account, branch_code: "123")).to be_valid
        expect(build(:singaporean_bank_account, branch_code: "1100")).not_to be_valid
        expect(build(:singaporean_bank_account, branch_code: "ABC")).not_to be_valid
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        expect(build(:singaporean_bank_account, account_number: "000123456")).to be_valid
        expect(build(:singaporean_bank_account, account_number: "1234567890")).to be_valid

        sg_bank_account = build(:singaporean_bank_account, account_number: "ABCDEFGHI")
        expect(sg_bank_account).not_to be_valid
        expect(sg_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        sg_bank_account = build(:singaporean_bank_account, account_number: "8937040044053201300000")
        expect(sg_bank_account).not_to be_valid
        expect(sg_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        sg_bank_account = build(:singaporean_bank_account, account_number: "CHABCDE")
        expect(sg_bank_account).not_to be_valid
        expect(sg_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end
end
