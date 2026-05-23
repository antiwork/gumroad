# frozen_string_literal: true

require "test_helper"

class JapanBankAccountTest < ActiveSupport::TestCase
  self.described_class = JapanBankAccount



  context_ JapanBankAccount do
  context_ "#bank_account_type" do
  test "returns Japan" do
        expect(create(:japan_bank_account).bank_account_type).to eq("JP")
      end
    end

  context_ "#country" do
  test "returns JP" do
        expect(create(:japan_bank_account).country).to eq("JP")
      end
    end

  context_ "#currency" do
  test "returns jpy" do
        expect(create(:japan_bank_account).currency).to eq("jpy")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 7 digits" do
        ba = create(:japan_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("1100000")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:japan_bank_account, account_number_last_four: "8912").account_number_visual).to eq("******8912")
      end
    end

  context_ "#validate_bank_code" do
  test "allows 4 digits only" do
        expect(build(:japan_bank_account, bank_code: "1100", branch_code: "000")).to be_valid
        expect(build(:japan_bank_account, bank_code: "BANK", branch_code: "000")).not_to be_valid

        expect(build(:japan_bank_account, bank_code: "ABC", branch_code: "000")).not_to be_valid
        expect(build(:japan_bank_account, bank_code: "123", branch_code: "000")).not_to be_valid
        expect(build(:japan_bank_account, bank_code: "TESTK", branch_code: "000")).not_to be_valid
        expect(build(:japan_bank_account, bank_code: "12345", branch_code: "000")).not_to be_valid
      end
    end

  context_ "#validate_branch_code" do
  test "allows 3 digits only" do
        expect(build(:japan_bank_account, bank_code: "1100", branch_code: "000")).to be_valid
        expect(build(:japan_bank_account, bank_code: "1100", branch_code: "ABC")).not_to be_valid

        expect(build(:japan_bank_account, bank_code: "1100", branch_code: "AB")).not_to be_valid
        expect(build(:japan_bank_account, bank_code: "1100", branch_code: "12")).not_to be_valid
        expect(build(:japan_bank_account, bank_code: "1100", branch_code: "TEST")).not_to be_valid
        expect(build(:japan_bank_account, bank_code: "1100", branch_code: "1234")).not_to be_valid
      end
    end

  context_ "#validate_account_number" do
  test "allows records that match the required account number regex" do
        expect(build(:japan_bank_account, account_number: "0001234")).to be_valid
        expect(build(:japan_bank_account, account_number: "1234")).to be_valid
        expect(build(:japan_bank_account, account_number: "12345678")).to be_valid

        jp_bank_account = build(:japan_bank_account, account_number: "ABCDEFG")
        expect(jp_bank_account).not_to be_valid
        expect(jp_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        jp_bank_account = build(:japan_bank_account, account_number: "123456789")
        expect(jp_bank_account).not_to be_valid
        expect(jp_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

        jp_bank_account = build(:japan_bank_account, account_number: "123")
        expect(jp_bank_account).not_to be_valid
        expect(jp_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end

  context_ "#validate_account_holder_full_name" do
  test "accepts Latin-only names with ASCII spaces" do
        expect(build(:japan_bank_account, account_holder_full_name: "Japanese Creator")).to be_valid
        expect(build(:japan_bank_account, account_holder_full_name: "Masashi")).to be_valid
      end

  test "accepts katakana-only names, including prolonged sound mark, middle dot, and full-width space" do
        expect(build(:japan_bank_account, account_holder_full_name: "ヤマダタロウ")).to be_valid
        expect(build(:japan_bank_account, account_holder_full_name: "コーヒー")).to be_valid
        expect(build(:japan_bank_account, account_holder_full_name: "ジョージ")).to be_valid
        expect(build(:japan_bank_account, account_holder_full_name: "ピーター・パン")).to be_valid
        expect(build(:japan_bank_account, account_holder_full_name: "ハルナ\u3000マサシ")).to be_valid
      end

  test "accepts half-width katakana names, including voiced and prolonged sound marks" do
        expect(build(:japan_bank_account, account_holder_full_name: "ﾔﾏﾀﾞ\u3000ﾀﾛｳ")).to be_valid
        expect(build(:japan_bank_account, account_holder_full_name: "ﾋﾟｰﾀｰ")).to be_valid
      end

  test "normalizes ASCII spaces to full-width when the rest is katakana (the incident case)" do
        account = build(:japan_bank_account, account_holder_full_name: "ハルナ マサシ")
        expect(account).to be_valid
        expect(account.account_holder_full_name).to eq("ハルナ　マサシ")
      end

  test "leaves ASCII spaces alone when the name is Latin-only" do
        account = build(:japan_bank_account, account_holder_full_name: "Masashi Haruna")
        expect(account).to be_valid
        expect(account.account_holder_full_name).to eq("Masashi Haruna")
      end

  test "rejects scripts outside the two allowed variants" do
        expect(build(:japan_bank_account, account_holder_full_name: "Haruna マサシ")).not_to be_valid
        expect(build(:japan_bank_account, account_holder_full_name: "春奈 正志")).not_to be_valid
        expect(build(:japan_bank_account, account_holder_full_name: "はるな")).not_to be_valid
        expect(build(:japan_bank_account, account_holder_full_name: "")).not_to be_valid
      end

  test "strips leading and trailing whitespace before validating" do
        account = build(:japan_bank_account, account_holder_full_name: "  Japanese Creator  ")
        expect(account).to be_valid
        expect(account.account_holder_full_name).to eq("Japanese Creator")
      end

  test "does not run on soft-delete so pre-validator invalid names can still be marked deleted" do
        account = create(:japan_bank_account)
        account.update_columns(account_holder_full_name: "Haruna マサシ")

        expect { account.mark_deleted! }.not_to raise_error
        expect(account.reload.deleted_at).to be_present
      end

  test "defers to the presence validator for blank input instead of adding a confusing format error" do
        account = build(:japan_bank_account, account_holder_full_name: "")
        expect(account).not_to be_valid
        expect(account.errors[:account_holder_full_name]).to be_present
        expect(account.errors[:account_holder_full_name].grep(/katakana or Latin/)).to be_empty
      end
    end
  end
end
