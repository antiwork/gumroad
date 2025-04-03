# frozen_string_literal: true

require "spec_helper"

describe SaudiArabiaBankAccount do
  describe "#bank_account_type" do
    it "returns SA" do
      expect(create(:saudi_arabia_bank_account).bank_account_type).to eq("SA")
    end
  end

  describe "#country" do
    it "returns SA" do
      expect(create(:saudi_arabia_bank_account).country).to eq("SA")
    end
  end

  describe "#currency" do
    it "returns sar" do
      expect(create(:saudi_arabia_bank_account).currency).to eq("sar")
    end
  end

  describe "#routing_number" do
    it "returns valid for 11 characters" do
      ba = create(:saudi_arabia_bank_account)
      expect(ba).to be_valid
      expect(ba.routing_number).to eq("RIBLSARIXXX")
    end
  end

  describe "#account_number_visual" do
    it "returns the visual account number" do
      expect(create(:saudi_arabia_bank_account, account_number_last_four: "7519").account_number_visual).to eq("******7519")
    end
  end

  describe "#validate_bank_code" do
    it "allows 8 to 11 characters only" do
      expect(build(:saudi_arabia_bank_account, bank_code: "RIBLSARIXXX")).to be_valid
      expect(build(:saudi_arabia_bank_account, bank_code: "RIBLSARI")).to be_valid
      expect(build(:saudi_arabia_bank_account, bank_code: "RIBLSAR")).not_to be_valid
      expect(build(:saudi_arabia_bank_account, bank_code: "RIBLSARIXXXX")).not_to be_valid
    end
  end
end
