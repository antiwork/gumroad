# frozen_string_literal: true

require "spec_helper"

describe PakistanBankAccount do
  describe "#bank_account_type" do
    it "returns Pakistan" do
      expect(create(:pakistan_bank_account).bank_account_type).to eq("PK")
    end
  end

  describe "#country" do
    it "returns PK" do
      expect(create(:pakistan_bank_account).country).to eq("PK")
    end
  end

  describe "#currency" do
    it "returns pkr" do
      expect(create(:pakistan_bank_account).currency).to eq("pkr")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:pakistan_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("AAAAPKKAXXX")
    end
  end

  describe "#stripe_external_account_routing_number" do
    it "uses the 8-character bank identifier for a branch-specific BIC" do
      ba = create(:pakistan_bank_account, bank_code: "HABBPKKA007")

      expect(ba.stripe_external_account_routing_number).to eq("HABBPKKA")
    end

    it "keeps an 8-character BIC unchanged" do
      ba = create(:pakistan_bank_account, bank_code: "HABBPKKA")

      expect(ba.stripe_external_account_routing_number).to eq("HABBPKKA")
    end

    it "keeps an 11-character head-office BIC unchanged" do
      ba = create(:pakistan_bank_account, bank_code: "HABBPKKAXXX")

      expect(ba.stripe_external_account_routing_number).to eq("HABBPKKAXXX")
    end

    it "upcases a lowercase head-office BIC" do
      ba = create(:pakistan_bank_account, bank_code: "habbpkkaxxx")

      expect(ba.stripe_external_account_routing_number).to eq("HABBPKKAXXX")
    end

    it "uses the 8-character bank identifier for a lowercase branch-specific BIC" do
      ba = create(:pakistan_bank_account, bank_code: "habbpkka007")

      expect(ba.stripe_external_account_routing_number).to eq("HABBPKKA")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:pakistan_bank_account, account_number_last_four: "6702").account_number_visual).to eq("******6702")
    end
  end

  describe "#validate_bank_code" do
    it "allows 8 to 11 characters only" do
      expect(build(:pakistan_bank_account, bank_code: "AAAAPKKAXXX")).to be_valid
      expect(build(:pakistan_bank_account, bank_code: "AAAAPKKA")).to be_valid
      expect(build(:pakistan_bank_account, bank_code: "AAAAPKK")).not_to be_valid
      expect(build(:pakistan_bank_account, bank_code: "AAAAPKKAXXXX")).not_to be_valid
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(build(:pakistan_bank_account)).to be_valid
      expect(build(:pakistan_bank_account, account_number: "PK36SCBL0000001123456702")).to be_valid

      pk_bank_account = build(:pakistan_bank_account, account_number: "PK12345")
      expect(pk_bank_account).to_not be_valid
      expect(pk_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      pk_bank_account = build(:pakistan_bank_account, account_number: "PK36SCBL00000011234567021")
      expect(pk_bank_account).to_not be_valid
      expect(pk_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      pk_bank_account = build(:pakistan_bank_account, account_number: "PK36SCBL000000112345670")
      expect(pk_bank_account).to_not be_valid
      expect(pk_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      pk_bank_account = build(:pakistan_bank_account, account_number: "PKABCDE")
      expect(pk_bank_account).to_not be_valid
      expect(pk_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end

  describe "#validate_iban_bank_is_routable" do
    def pk_iban(bank_code)
      bban = "#{bank_code}0000001123456702"
      check = 98 - "#{bban}PK00".chars.map { |c| c.to_i(36) }.join.to_i % 97
      format("PK%02d%s", check, bban)
    end

    it "rejects a wallet IBAN whatever the BIC" do
      ["SADAPKKA", "HABBPKKA"].each do |bank_code|
        bank_account = build(:pakistan_bank_account, account_number: pk_iban("SADA"), bank_code:)

        expect(bank_account).not_to be_valid
        expect(bank_account.errors.full_messages.to_sentence).to start_with("We can't send payouts to this IBAN.")
      end
    end

    it "accepts a bank IBAN whose BIC names a different bank" do
      expect(build(:pakistan_bank_account, account_number: pk_iban("BAHL"), bank_code: "HABBPKKA")).to be_valid
    end

    it "does not block deleting an existing wallet row" do
      bank_account = build(:pakistan_bank_account, account_number: pk_iban("NAYA"))
      bank_account.save!(validate: false)

      bank_account.mark_deleted!

      expect(bank_account.reload).to be_deleted
    end
  end
end
