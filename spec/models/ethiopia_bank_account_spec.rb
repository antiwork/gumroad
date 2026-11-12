# frozen_string_literal: true

describe EthiopiaBankAccount do
  describe "#bank_account_type" do
    it "returns ET" do
      expect(create(:ethiopia_bank_account).bank_account_type).to eq("ET")
    end
  end

  describe "#country" do
    it "returns ET" do
      expect(create(:ethiopia_bank_account).country).to eq("ET")
    end
  end

  describe "#currency" do
    it "returns etb" do
      expect(create(:ethiopia_bank_account).currency).to eq("etb")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:ethiopia_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAAETETXXX")
    end
  end

  describe "#validate_bank_code" do
    it "allows the 8-character BIC and its 11-character branch-suffixed form" do
      expect(build(:ethiopia_bank_account, bank_code: "CBETETAA")).to be_valid
      expect(build(:ethiopia_bank_account, bank_code: "CBETETAAXXX")).to be_valid
      expect(build(:ethiopia_bank_account, bank_code: "CBETETAAX")).not_to be_valid
      expect(build(:ethiopia_bank_account, bank_code: "0914706005")).not_to be_valid
      expect(build(:ethiopia_bank_account, bank_code: "CBETET")).not_to be_valid
      expect(build(:ethiopia_bank_account, bank_code: "CBETETAAXXXX")).not_to be_valid
      expect(build(:ethiopia_bank_account, bank_code: "CBETET AA")).not_to be_valid
    end

    it "accepts a lowercase code, which the sync path upcases before Stripe sees it" do
      bank_account = build(:ethiopia_bank_account, bank_code: "cbetetaa")

      expect(bank_account).to be_valid
      expect(bank_account.stripe_external_account_routing_number).to eq("CBETETAA")
    end

    it "does not block saves of an already-stored code that predates this format check" do
      bank_account = build(:ethiopia_bank_account, bank_code: "CBETETTAX")
      bank_account.save!(validate: false)

      bank_account.account_holder_full_name = "Renamed Seller"
      expect(bank_account.save).to be(true)
      expect { bank_account.mark_deleted! }.not_to raise_error
      expect(bank_account.reload.deleted_at).to be_present
    end

    it "still rejects the code once the seller edits it" do
      bank_account = build(:ethiopia_bank_account, bank_code: "CBETETTAX")
      bank_account.save!(validate: false)

      bank_account.bank_code = "CBETETAAXX"
      expect(bank_account).not_to be_valid
      expect(bank_account.errors.full_messages).to eq(["The bank code is invalid."])
    end

    it "accepts an edit that corrects the code" do
      bank_account = build(:ethiopia_bank_account, bank_code: "CBETETTAX")
      bank_account.save!(validate: false)

      bank_account.bank_code = "CBETETAA"
      expect(bank_account).to be_valid
    end
  end

  describe "bank code country" do
    it "rejects a BIC registered outside Ethiopia" do
      bank_account = build(:ethiopia_bank_account, bank_number: "BOFAUS3N")

      expect(bank_account).not_to be_valid
      expect(bank_account.errors.full_messages.join).to include("must be for a bank in Ethiopia")
      expect(bank_account.errors.full_messages.join).to include("United States")
    end

    it "accepts an Ethiopian BIC" do
      expect(build(:ethiopia_bank_account, bank_number: "CBETETAA")).to be_valid
      expect(build(:ethiopia_bank_account, bank_number: "AWINETAAXXX")).to be_valid
    end

    it "accepts a lowercase Ethiopian BIC" do
      expect(build(:ethiopia_bank_account, bank_number: "awinetaa")).to be_valid
    end

    it "rejects a foreign BIC padded past the format check with a newline" do
      expect(build(:ethiopia_bank_account, bank_number: "BOFAUS3N\nXXXX")).not_to be_valid
    end

    # The rows this rule rejects are already in the table, and every account-ending path saves
    # them through a validating mark_deleted!.
    describe "a persisted row whose stored BIC names another country" do
      let(:bank_account) do
        account = build(:ethiopia_bank_account, bank_number: "BOFAUS3N")
        account.save!(validate: false)
        account
      end

      it "can still be soft-deleted" do
        expect { bank_account.mark_deleted! }.to change { bank_account.reload.deleted_at }.from(nil)
      end

      it "still rejects the code once the seller edits it" do
        bank_account.bank_number = "DAHISOSM"

        expect(bank_account).not_to be_valid
      end

      it "accepts an edit that corrects the country" do
        bank_account.bank_number = "CBETETAA"

        expect(bank_account).to be_valid
      end
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:ethiopia_bank_account, account_number_last_four: "2345").account_number_visual).to eq("******2345")
    end
  end

  describe "#validate_account_number" do
    it "allows 13 to 16 digits" do
      expect(build(:ethiopia_bank_account)).to be_valid
      expect(build(:ethiopia_bank_account, account_number: "0000000012345")).to be_valid
      expect(build(:ethiopia_bank_account, account_number: "00000000123456")).to be_valid
      expect(build(:ethiopia_bank_account, account_number: "000000001234567")).to be_valid
      expect(build(:ethiopia_bank_account, account_number: "0000000012345678")).to be_valid
    end

    it "rejects the shapes Stripe's ET rail refuses" do
      expect(build(:ethiopia_bank_account, account_number: "000000001234")).not_to be_valid
      expect(build(:ethiopia_bank_account, account_number: "00000000123456789")).not_to be_valid
      expect(build(:ethiopia_bank_account, account_number: "ET00000012345678")).not_to be_valid
      expect(build(:ethiopia_bank_account, account_number: "0001234567ABCD")).not_to be_valid
    end

    it "names the expected format in the error" do
      et_bank_account = build(:ethiopia_bank_account, account_number: "0001234567ABCD")
      et_bank_account.valid?
      expect(et_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end

    it "rejects a new row with no account number" do
      expect(build(:ethiopia_bank_account, account_number: nil)).not_to be_valid
    end

    it "does not re-validate a pre-existing alphanumeric number on an unrelated save" do
      ba = build(:ethiopia_bank_account, account_number: "ET00000012345678")
      ba.save!(validate: false)

      expect(ba.mark_deleted!).to be_truthy
      expect(ba.reload).to be_deleted
    end

    it "still rejects a bad number when the number itself is being changed" do
      ba = build(:ethiopia_bank_account, account_number: "ET00000012345678")
      ba.save!(validate: false)

      ba.account_number = "0001234567ABCD"
      expect(ba).not_to be_valid
    end

    it "allows a pre-existing alphanumeric number to be corrected" do
      ba = build(:ethiopia_bank_account, account_number: "ET00000012345678")
      ba.save!(validate: false)

      ba.account_number = "0000000012345"
      expect(ba).to be_valid
    end
  end
end
