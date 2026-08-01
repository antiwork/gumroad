# frozen_string_literal: true

describe NigeriaBankAccount do
  describe "#bank_account_type" do
    it "returns NG" do
      expect(create(:nigeria_bank_account).bank_account_type).to eq("NG")
    end
  end

  describe "#country" do
    it "returns NG" do
      expect(create(:nigeria_bank_account).country).to eq("NG")
    end
  end

  describe "#currency" do
    it "returns ngn" do
      expect(create(:nigeria_bank_account).currency).to eq("ngn")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:nigeria_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAANGLAXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:nigeria_bank_account, account_number_last_four: "1112").account_number_visual).to eq("NG******1112")
    end
  end

  describe "bank code country" do
    it "rejects a BIC registered outside Nigeria" do
      # OPay's UK BIC: 250 live rows saved it and not one ever attached to Stripe.
      ba = build(:nigeria_bank_account, bank_number: "OPAHGB22")

      expect(ba).not_to be_valid
      expect(ba.errors.full_messages.join).to include("must be for a bank in Nigeria")
      expect(ba.errors.full_messages.join).to include("United Kingdom")
    end

    it "accepts a Nigerian BIC" do
      expect(build(:nigeria_bank_account, bank_number: "ABNGNGLAXXX")).to be_valid
    end

    it "accepts a lowercase Nigerian BIC" do
      expect(build(:nigeria_bank_account, bank_number: "abngngla")).to be_valid
    end

    it "leaves a non-BIC code to the format validator" do
      expect(build(:nigeria_bank_account, bank_number: "02607315")).to be_valid
    end

    it "rejects a foreign BIC padded past the format check with a newline" do
      expect(build(:nigeria_bank_account, bank_number: "OPAHGB22\nXXXX")).not_to be_valid
    end

    # The rows this rule rejects are already in the table, and every account-ending path saves
    # them through a validating mark_deleted!.
    describe "a persisted row whose stored BIC names another country" do
      let(:bank_account) do
        account = build(:nigeria_bank_account, bank_number: "OPAHGB22")
        account.save!(validate: false)
        account
      end

      it "can still be soft-deleted" do
        expect { bank_account.mark_deleted! }.to change { bank_account.reload.deleted_at }.from(nil)
      end

      it "still rejects the code once the seller edits it" do
        bank_account.bank_number = "TRWIUS35"

        expect(bank_account).not_to be_valid
      end

      it "accepts an edit that corrects the country" do
        bank_account.bank_number = "ABNGNGLAXXX"

        expect(bank_account).to be_valid
      end
    end
  end
end
