# frozen_string_literal: true

require "spec_helper"

describe JapanBankAccount do
  describe "#bank_account_type" do
    it "returns Japan" do
      expect(create(:japan_bank_account).bank_account_type).to eq("JP")
    end
  end

  describe "#country" do
    it "returns JP" do
      expect(create(:japan_bank_account).country).to eq("JP")
    end
  end

  describe "#currency" do
    it "returns jpy" do
      expect(create(:japan_bank_account).currency).to eq("jpy")
    end
  end

  describe "#routing_number" do
    it "returns valid for 7 digits" do
      ba = create(:japan_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("1100000")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:japan_bank_account, account_number_last_four: "8912").account_number_visual).to eq("******8912")
    end
  end

  describe "#validate_bank_code" do
    it "allows 4 digits only" do
      expect(build(:japan_bank_account, bank_code: "1100", branch_code: "000")).to be_valid
      expect(build(:japan_bank_account, bank_code: "BANK", branch_code: "000")).not_to be_valid

      expect(build(:japan_bank_account, bank_code: "ABC", branch_code: "000")).not_to be_valid
      expect(build(:japan_bank_account, bank_code: "123", branch_code: "000")).not_to be_valid
      expect(build(:japan_bank_account, bank_code: "TESTK", branch_code: "000")).not_to be_valid
      expect(build(:japan_bank_account, bank_code: "12345", branch_code: "000")).not_to be_valid
    end
  end

  describe "#validate_branch_code" do
    it "allows 3 digits only" do
      expect(build(:japan_bank_account, bank_code: "1100", branch_code: "000")).to be_valid
      expect(build(:japan_bank_account, bank_code: "1100", branch_code: "ABC")).not_to be_valid

      expect(build(:japan_bank_account, bank_code: "1100", branch_code: "AB")).not_to be_valid
      expect(build(:japan_bank_account, bank_code: "1100", branch_code: "12")).not_to be_valid
      expect(build(:japan_bank_account, bank_code: "1100", branch_code: "TEST")).not_to be_valid
      expect(build(:japan_bank_account, bank_code: "1100", branch_code: "1234")).not_to be_valid
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      expect(build(:japan_bank_account, account_number: "0001234")).to be_valid
      expect(build(:japan_bank_account, account_number: "1234")).to be_valid
      expect(build(:japan_bank_account, account_number: "12345678")).to be_valid

      jp_bank_account = build(:japan_bank_account, account_number: "ABCDEFG")
      expect(jp_bank_account).to_not be_valid
      expect(jp_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      jp_bank_account = build(:japan_bank_account, account_number: "123456789")
      expect(jp_bank_account).to_not be_valid
      expect(jp_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      jp_bank_account = build(:japan_bank_account, account_number: "123")
      expect(jp_bank_account).to_not be_valid
      expect(jp_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end

  describe "#validate_account_holder_full_name" do
    it "accepts Latin-only names with ASCII spaces" do
      expect(build(:japan_bank_account, account_holder_full_name: "Japanese Creator")).to be_valid
      expect(build(:japan_bank_account, account_holder_full_name: "Masashi")).to be_valid
    end

    it "accepts katakana-only names, including prolonged sound mark, middle dot, and full-width space" do
      expect(build(:japan_bank_account, account_holder_full_name: "ヤマダタロウ")).to be_valid
      expect(build(:japan_bank_account, account_holder_full_name: "コーヒー")).to be_valid
      expect(build(:japan_bank_account, account_holder_full_name: "ジョージ")).to be_valid
      expect(build(:japan_bank_account, account_holder_full_name: "ピーター・パン")).to be_valid
      expect(build(:japan_bank_account, account_holder_full_name: "ハルナ\u3000マサシ")).to be_valid
    end

    it "accepts half-width katakana names, including voiced and prolonged sound marks" do
      expect(build(:japan_bank_account, account_holder_full_name: "ﾔﾏﾀﾞ\u3000ﾀﾛｳ")).to be_valid
      expect(build(:japan_bank_account, account_holder_full_name: "ﾋﾟｰﾀｰ")).to be_valid
    end

    it "rejects katakana mixed with ASCII space (the incident case)" do
      account = build(:japan_bank_account, account_holder_full_name: "ハルナ マサシ")
      expect(account).to_not be_valid
      expect(account.errors[:account_holder_full_name]).to be_present
    end

    it "rejects scripts outside the two allowed variants" do
      expect(build(:japan_bank_account, account_holder_full_name: "Haruna マサシ")).to_not be_valid
      expect(build(:japan_bank_account, account_holder_full_name: "春奈 正志")).to_not be_valid
      expect(build(:japan_bank_account, account_holder_full_name: "はるな")).to_not be_valid
      expect(build(:japan_bank_account, account_holder_full_name: "")).to_not be_valid
    end

    it "strips leading and trailing whitespace before validating" do
      account = build(:japan_bank_account, account_holder_full_name: "  Japanese Creator  ")
      expect(account).to be_valid
      expect(account.account_holder_full_name).to eq("Japanese Creator")
    end

    it "does not run on soft-delete so pre-validator invalid names can still be marked deleted" do
      account = create(:japan_bank_account)
      account.update_columns(account_holder_full_name: "ハルナ マサシ")

      expect { account.mark_deleted! }.not_to raise_error
      expect(account.reload.deleted_at).to be_present
    end

    it "defers to the presence validator for blank input instead of adding a confusing format error" do
      account = build(:japan_bank_account, account_holder_full_name: "")
      expect(account).to_not be_valid
      expect(account.errors[:account_holder_full_name]).to be_present
      expect(account.errors[:account_holder_full_name].grep(/katakana or Latin/)).to be_empty
    end
  end
end
