# frozen_string_literal: true

describe BosniaAndHerzegovinaBankAccount do
  describe "#bank_account_type" do
    it "returns BA" do
      expect(create(:bosnia_and_herzegovina_bank_account).bank_account_type).to eq("BA")
    end
  end

  describe "#country" do
    it "returns BA" do
      expect(create(:bosnia_and_herzegovina_bank_account).country).to eq("BA")
    end
  end

  describe "#currency" do
    it "returns bam" do
      expect(create(:bosnia_and_herzegovina_bank_account).currency).to eq("bam")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:bosnia_and_herzegovina_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAABABAXXX")
    end
  end

  describe "#validate_bank_code" do
    it "allows an 8-character BIC or an 11-character BIC with branch suffix" do
      expect(build(:bosnia_and_herzegovina_bank_account, bank_code: "UNCRBA22")).to be_valid
      expect(build(:bosnia_and_herzegovina_bank_account, bank_code: "UNCRBA22XXX")).to be_valid
      expect(build(:bosnia_and_herzegovina_bank_account, bank_code: "UNCRBA2")).not_to be_valid
      expect(build(:bosnia_and_herzegovina_bank_account, bank_code: "UNCRBA22X")).not_to be_valid
      expect(build(:bosnia_and_herzegovina_bank_account, bank_code: "UNCRBA22XX")).not_to be_valid
      expect(build(:bosnia_and_herzegovina_bank_account, bank_code: "UNCRBA22XXXX")).not_to be_valid
      expect(build(:bosnia_and_herzegovina_bank_account, bank_code: "UNCRBA22-XX")).not_to be_valid
    end

    it "allows an 11-character BIC with a non-XXX alphanumeric branch suffix" do
      expect(build(:bosnia_and_herzegovina_bank_account, bank_code: "UNCRBA22A12")).to be_valid
    end

    %w[UNCRBA22X UNCRBA22XX].each do |bank_code|
      it "rejects a persisted bank_code edit to #{bank_code.length} characters without changing the stored value" do
        bank_account = create(:bosnia_and_herzegovina_bank_account, bank_code: "UNCRBA22")

        expect(bank_account.update(bank_code:)).to be(false)
        expect(bank_account.errors.full_messages).to eq(["The bank code is invalid."])
        expect(bank_account.reload.bank_code).to eq("UNCRBA22")
      end
    end

    %w[UNCRBA22X UNCRBA22XX].each do |legacy_bank_code|
      %w[UNCRBA22 UNCRBA22XXX].each do |bank_code|
        it "corrects a legacy #{legacy_bank_code.length}-character bank_code to #{bank_code.length} characters" do
          bank_account = build(:bosnia_and_herzegovina_bank_account, bank_code: legacy_bank_code)
          bank_account.save!(validate: false)

          expect(bank_account.update(bank_code:)).to be(true)
          expect(bank_account.reload.bank_code).to eq(bank_code)
        end
      end
    end

    it "does not block saves of an already-stored code that predates this format check" do
      bank_account = build(:bosnia_and_herzegovina_bank_account, bank_code: "UNCRBA22XX")
      bank_account.save!(validate: false)

      bank_account.account_holder_full_name = "Renamed Seller"
      expect(bank_account.save).to be(true)
      expect { bank_account.mark_deleted! }.not_to raise_error
      expect(bank_account.reload.deleted_at).to be_present
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:bosnia_and_herzegovina_bank_account, account_number_last_four: "6000").account_number_visual).to eq("BA******6000")
    end
  end
end
