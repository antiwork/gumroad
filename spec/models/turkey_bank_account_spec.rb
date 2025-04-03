# frozen_string_literal: true

require "spec_helper"

describe TurkeyBankAccount do
  describe "#bank_account_type" do
    it "returns Turkey" do
      expect(create(:turkey_bank_account).bank_account_type).to eq("TR")
    end
  end

  describe "#country" do
    it "returns TR" do
      expect(create(:turkey_bank_account).country).to eq("TR")
    end
  end

  describe "#currency" do
    it "returns try" do
      expect(create(:turkey_bank_account).currency).to eq("try")
    end
  end

  describe "#routing_number" do
    it "returns valid for 8 characters" do
      ba = create(:turkey_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("ADABTRIS")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:turkey_bank_account, account_number_last_four: "1326").account_number_visual).to eq("******1326")
    end
  end

  describe "#validate_bank_code" do
    it "allows 8 to 11 characters only" do
      expect(build(:turkey_bank_account, bank_code: "ADABTRISXXX")).to be_valid
      expect(build(:turkey_bank_account, bank_code: "ADABTRIS")).to be_valid
      expect(build(:turkey_bank_account, bank_code: "ADABTRI")).not_to be_valid
      expect(build(:turkey_bank_account, bank_code: "ADABTRISXXXX")).not_to be_valid
    end
  end

  describe "#validate_account_number" do
    it "allows records that match the required account number regex" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(build(:turkey_bank_account)).to be_valid
      expect(build(:turkey_bank_account, account_number: "TR320010009999901234567890")).to be_valid

      tr_bank_account = build(:turkey_bank_account, account_number: "TR12345")
      expect(tr_bank_account).to_not be_valid
      expect(tr_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      tr_bank_account = build(:turkey_bank_account, account_number: "TR3200100099999012345678901")
      expect(tr_bank_account).to_not be_valid
      expect(tr_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      tr_bank_account = build(:turkey_bank_account, account_number: "TR32001000999990123456789")
      expect(tr_bank_account).to_not be_valid
      expect(tr_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")

      tr_bank_account = build(:turkey_bank_account, account_number: "TRABCDE")
      expect(tr_bank_account).to_not be_valid
      expect(tr_bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
    end
  end
end
