# frozen_string_literal: true

describe MoroccoBankAccount do
  describe "#bank_account_type" do
    it "returns Morocco" do
      expect(create(:morocco_bank_account).bank_account_type).to eq("MA")
    end
  end

  describe "#country" do
    it "returns MA" do
      expect(create(:morocco_bank_account).country).to eq("MA")
    end
  end

  describe "#currency" do
    it "returns mad" do
      expect(create(:morocco_bank_account).currency).to eq("mad")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:morocco_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAAMAMAXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:morocco_bank_account, account_number_last_four: "9123").account_number_visual).to eq("MA******9123")
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(build(:morocco_bank_account)).to be_valid
      expect(build(:morocco_bank_account, account_number: "MA64011519000001205000534921")).to be_valid

      # Stripe accepts only the full 28-character MA IBAN, and it checks the mod-97 check digits
      # too, so both a wrong length and a bad checksum must fail here rather than at bank-sync.
      [
        "MA99011519000001205000534921",   # 28 chars, check digits do not compute
        "MA6401151900000120500053492",    # 27 chars
        "MA640115190000012050005349211",  # 29 chars
        "MA62370400440532013001",         # 22 chars, the RIB-with-MA shape sellers actually enter
        "MA12345",
        "DE61109010140000071219812874",
        "8937040044053201300000",
        "CRABCDE",
      ].each do |account_number|
        ma_bank_account = build(:morocco_bank_account, account_number:)
        expect(ma_bank_account).to_not be_valid
        expect(ma_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid. Enter your 28-character IBAN: MA followed by 26 digits, not your RIB.")
      end

      # A blank number never marks the attribute dirty, so the format check is skipped and the
      # base class's presence validation is what rejects it.
      ma_bank_account = build(:morocco_bank_account, account_number: "")
      expect(ma_bank_account).to_not be_valid
      expect(ma_bank_account.errors.full_messages).to include("Account number We could not save your bank account information.")
    end

    it "leaves an already-persisted non-conforming account number alone on an unrelated save" do
      ma_bank_account = build(:morocco_bank_account, account_number: "MA62370400440532013001", account_number_last_four: "3001")
      ma_bank_account.save!(validate: false)

      allow(Rails.env).to receive(:production?).and_return(true)

      # Soft-deleting happens when a seller switches to PayPal, after their balance is already
      # forfeited, so re-validating the stored number here would raise mid-way through.
      expect { ma_bank_account.reload.mark_deleted! }.to_not raise_error
      expect(ma_bank_account.reload).to be_deleted
    end

    it "still rejects a non-conforming account number when one is being written to an existing record" do
      ma_bank_account = create(:morocco_bank_account)

      allow(Rails.env).to receive(:production?).and_return(true)

      ma_bank_account.account_number = "MA62370400440532013001"
      expect(ma_bank_account).to_not be_valid
      expect(ma_bank_account.errors.full_messages).to include("The account number is invalid. Enter your 28-character IBAN: MA followed by 26 digits, not your RIB.")
    end
  end
end
