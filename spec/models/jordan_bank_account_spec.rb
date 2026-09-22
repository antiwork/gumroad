# frozen_string_literal: true

describe JordanBankAccount do
  describe "#bank_account_type" do
    it "returns JO" do
      expect(create(:jordan_bank_account).bank_account_type).to eq("JO")
    end
  end

  describe "#country" do
    it "returns JO" do
      expect(create(:jordan_bank_account).country).to eq("JO")
    end
  end

  describe "#currency" do
    it "returns jod" do
      expect(create(:jordan_bank_account).currency).to eq("jod")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:jordan_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAAJOJOXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:jordan_bank_account, account_number_last_four: "5678").account_number_visual).to eq("JO******5678")
    end
  end

  describe "bank code validation" do
    it "accepts the 8-character primary BIC" do
      expect(build(:jordan_bank_account, bank_code: "IIBAJOAM")).to be_valid
    end

    it "accepts the 11-character XXX-padded form" do
      expect(build(:jordan_bank_account, bank_code: "IIBAJOAMXXX")).to be_valid
    end

    it "rejects a 9-character bank code" do
      ba = build(:jordan_bank_account, bank_code: "IIBAJOAMX")
      expect(ba).not_to be_valid
      expect(ba.errors[:base]).to include("Enter your bank's SWIFT/BIC code in capitals: 8 characters, or 11 including the branch code (for example IIBAJOAM).")
    end

    it "rejects a 10-character bank code" do
      expect(build(:jordan_bank_account, bank_code: "IIBAJOAMXX")).not_to be_valid
    end

    it "accepts an 11-character branch-suffixed code, which only the directory can resolve" do
      expect(build(:jordan_bank_account, bank_code: "IIBAJOAM200")).to be_valid
    end

    it "rejects a bank code in lowercase" do
      expect(build(:jordan_bank_account, bank_code: "iibajoam")).not_to be_valid
    end

    it "rejects a BIC whose country positions are not JO" do
      expect(build(:jordan_bank_account, bank_code: "IIBAUSAM")).not_to be_valid
      expect(build(:jordan_bank_account, bank_code: "IIBAGB2L")).not_to be_valid
    end

    it "does not re-validate a stored bank code on an unrelated save" do
      ba = create(:jordan_bank_account, bank_code: "IIBAJOAM")
      ba.update_column(:bank_number, "IIBAJOAMX")

      expect(ba.reload).to be_valid
      expect { ba.update!(account_holder_full_name: "Jordanian Creator II") }.not_to raise_error
    end

    it "validates a stored bank code again when the field itself changes" do
      ba = create(:jordan_bank_account, bank_code: "IIBAJOAM")
      ba.bank_code = "IIBAJOAMX"

      expect(ba).not_to be_valid
    end

    ["IIBAJOAM\n", "\nIIBAJOAM", "invalid\nIIBAJOAM\ninvalid", "IIBAJOAM200\n"].each do |bank_code|
      it "rejects the entire input #{bank_code.inspect} on creation" do
        ba = build(:jordan_bank_account, bank_code:)

        expect(ba.save).to be(false)
        expect(ba.errors[:base]).to include("Enter your bank's SWIFT/BIC code in capitals: 8 characters, or 11 including the branch code (for example IIBAJOAM).")
      end
    end

    [nil, "", " IIBAJOAM", "IIBAJOAM ", "1IBAJOAM", "IIBAJOA-", "IIBAJOAM20a"].each do |bank_code|
      it "rejects #{bank_code.inspect} without normalizing it" do
        ba = build(:jordan_bank_account, bank_code:)

        expect(ba).not_to be_valid
        expect(ba.bank_code).to eq(bank_code)
      end
    end

    [nil, "IIBAJOAM\n"].each do |bank_number|
      it "rejects changing bank_number to #{bank_number.inspect}" do
        ba = create(:jordan_bank_account, bank_code: "IIBAJOAM")

        expect(ba.update(bank_number:)).to be(false)
        expect(ba.reload.bank_code).to eq("IIBAJOAM")
      end
    end

    [nil, "IIBAJOAMX", "IIBAJOAM\n"].each do |bank_number|
      it "preserves legacy #{bank_number.inspect} through unrelated saves and deletion" do
        ba = create(:jordan_bank_account)
        ba.update_column(:bank_number, bank_number)
        ba.reload

        ba.update!(account_holder_full_name: "Jordanian Creator II")
        expect(ba.reload.bank_number).to eq(bank_number)
        ba.mark_deleted!
        expect(ba.reload).to be_deleted
        expect(ba.bank_number).to eq(bank_number)
      end
    end

    it "saves a valid replacement through the bank_code alias" do
      ba = create(:jordan_bank_account)
      ba.update_column(:bank_number, "IIBAJOAMX")

      ba.reload.update!(bank_code: "IIBAJOA1200")

      expect(ba.reload.bank_number).to eq("IIBAJOA1200")
    end
  end
end
