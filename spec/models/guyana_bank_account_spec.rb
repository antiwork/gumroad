# frozen_string_literal: true

describe GuyanaBankAccount do
  describe "#bank_account_type" do
    it "returns GY" do
      expect(create(:guyana_bank_account).bank_account_type).to eq("GY")
    end
  end

  describe "#country" do
    it "returns GY" do
      expect(create(:guyana_bank_account).country).to eq("GY")
    end
  end

  describe "#currency" do
    it "returns gyd" do
      expect(create(:guyana_bank_account).currency).to eq("gyd")
    end
  end

  describe "#routing_number" do
    it "joins the bank code and branch code with a dash" do
      ba = create(:guyana_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAAGYGGXYZ-12345678")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:guyana_bank_account, account_number_last_four: "6789").account_number_visual).to eq("******6789")
    end
  end

  describe "#validate_bank_code" do
    it "requires exactly 11 alphanumeric characters" do
      expect(build(:guyana_bank_account)).to be_valid
      expect(build(:guyana_bank_account, bank_code: "AAAAGYGGXXX")).to be_valid

      ba = build(:guyana_bank_account, bank_code: "AAAAGYGG")
      expect(ba).to_not be_valid
      expect(ba.errors.full_messages.to_sentence).to eq("The bank code is invalid.")

      ba = build(:guyana_bank_account, bank_code: "AAAAGYGGXX")
      expect(ba).to_not be_valid
      expect(ba.errors.full_messages.to_sentence).to eq("The bank code is invalid.")

      ba = build(:guyana_bank_account, bank_code: "AAAAGYGGXXXX")
      expect(ba).to_not be_valid
      expect(ba.errors.full_messages.to_sentence).to eq("The bank code is invalid.")

      ba = build(:guyana_bank_account, bank_code: "AAAAGYGG-XX")
      expect(ba).to_not be_valid
      expect(ba.errors.full_messages.to_sentence).to eq("The bank code is invalid.")
    end
  end

  describe "#validate_branch_code" do
    it "requires exactly 8 digits" do
      expect(build(:guyana_bank_account, branch_code: "12345678")).to be_valid
      expect(build(:guyana_bank_account, branch_code: "00000000")).to be_valid

      ba = build(:guyana_bank_account, branch_code: "1234567")
      expect(ba).to_not be_valid
      expect(ba.errors.full_messages.to_sentence).to eq("The branch code is invalid.")

      ba = build(:guyana_bank_account, branch_code: "123456789")
      expect(ba).to_not be_valid
      expect(ba.errors.full_messages.to_sentence).to eq("The branch code is invalid.")

      ba = build(:guyana_bank_account, branch_code: "abcdefgh")
      expect(ba).to_not be_valid
      expect(ba.errors.full_messages.to_sentence).to eq("The branch code is invalid.")

      ba = build(:guyana_bank_account, branch_code: "")
      expect(ba).to_not be_valid
      expect(ba.errors.full_messages.to_sentence).to eq("The branch code is invalid.")
    end
  end

  describe "validations on legacy records" do
    it "skips bank_code and branch_code checks when neither has changed" do
      ba = create(:guyana_bank_account)
      ba.update_columns(bank_number: "AAAAGYGG", branch_code: nil)
      ba.reload

      ba.account_holder_full_name = "Renamed Creator"
      expect(ba.save).to eq(true)
    end

    it "validates branch_code when it changes on a legacy record" do
      ba = create(:guyana_bank_account)
      ba.update_columns(branch_code: nil)
      ba.reload

      ba.branch_code = "123"
      expect(ba).to_not be_valid
      expect(ba.errors.full_messages.to_sentence).to eq("The branch code is invalid.")
    end

    it "validates bank_code when it changes on a legacy record" do
      ba = create(:guyana_bank_account)
      ba.update_columns(bank_number: "AAAAGYGG")
      ba.reload

      ba.bank_code = "TOOSHORT"
      expect(ba).to_not be_valid
      expect(ba.errors.full_messages.to_sentence).to eq("The bank code is invalid.")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      expect(build(:guyana_bank_account)).to be_valid
      expect(build(:guyana_bank_account, account_number: "00012345678910111213141516171819")).to be_valid
      expect(build(:guyana_bank_account, account_number: "1")).to be_valid
      expect(build(:guyana_bank_account, account_number: "GUY12345678910111213141516171819")).to be_valid

      gy_bank_account = build(:guyana_bank_account, account_number: "0001234567891011121314151617181920")
      expect(gy_bank_account).to_not be_valid
      expect(gy_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      gy_bank_account = build(:guyana_bank_account, account_number: "GUY1234567891011121314151617181920")
      expect(gy_bank_account).to_not be_valid
      expect(gy_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
