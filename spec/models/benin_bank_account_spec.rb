# frozen_string_literal: true

describe BeninBankAccount do
  describe "#bank_account_type" do
    it "returns BJ" do
      expect(create(:benin_bank_account).bank_account_type).to eq("BJ")
    end
  end

  describe "#country" do
    it "returns BJ" do
      expect(create(:benin_bank_account).country).to eq("BJ")
    end
  end

  describe "#currency" do
    it "returns xof" do
      expect(create(:benin_bank_account).currency).to eq("xof")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:benin_bank_account, account_number_last_four: "0769").account_number_visual).to eq("BJ******0769")
    end
  end

  describe "#routing_number" do
    it "returns nil" do
      expect(create(:benin_bank_account).routing_number).to be nil
    end
  end

  describe "#validate_account_number" do
    let(:message) { "The account number is invalid. Enter your 28-character IBAN starting with BJ and check the two digits after BJ." }

    it "accepts a 28-character IBAN with valid check digits" do
      expect(build(:benin_bank_account)).to be_valid
    end

    it "rejects values Stripe rejects" do
      [
        "BJ00BC0010100100045000000110", # 28 chars, check digits do not compute
        "BJ66AJ06101001001KR390000760",
        "FR66BJ0610100100144390000769",
        "BJ66BJ061010010014439000076",
        "BJ66BJ06101001001443900007690",
        "9066890610100100144390000769",
      ].each do |account_number|
        bj_bank_account = build(:benin_bank_account, account_number:)
        expect(bj_bank_account).to_not be_valid
        expect(bj_bank_account.errors.full_messages.to_sentence).to eq(message)
      end
    end

    it "leaves an already-persisted non-conforming number alone on an unrelated save" do
      bj_bank_account = build(:benin_bank_account, account_number: "BJ00BC0010100100045000000110", account_number_last_four: "0110")
      bj_bank_account.save!(validate: false)

      expect { bj_bank_account.reload.mark_deleted! }.to_not raise_error
      expect(bj_bank_account.reload).to be_deleted
    end
  end
end
