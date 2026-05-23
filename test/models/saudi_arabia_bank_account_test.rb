# frozen_string_literal: true

require "test_helper"

class SaudiArabiaBankAccountTest < ActiveSupport::TestCase
  self.described_class = SaudiArabiaBankAccount



  context_ SaudiArabiaBankAccount do
  context_ "#bank_account_type" do
  test "returns SA" do
        expect(create(:saudi_arabia_bank_account).bank_account_type).to eq("SA")
      end
    end

  context_ "#country" do
  test "returns SA" do
        expect(create(:saudi_arabia_bank_account).country).to eq("SA")
      end
    end

  context_ "#currency" do
  test "returns sar" do
        expect(create(:saudi_arabia_bank_account).currency).to eq("sar")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 11 characters" do
        ba = create(:saudi_arabia_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("RIBLSARIXXX")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:saudi_arabia_bank_account, account_number_last_four: "7519").account_number_visual).to eq("******7519")
      end
    end

  context_ "#validate_bank_code" do
  test "allows 8 to 11 characters only" do
        expect(build(:saudi_arabia_bank_account, bank_code: "RIBLSARIXXX")).to be_valid
        expect(build(:saudi_arabia_bank_account, bank_code: "RIBLSARI")).to be_valid
        expect(build(:saudi_arabia_bank_account, bank_code: "RIBLSAR")).not_to be_valid
        expect(build(:saudi_arabia_bank_account, bank_code: "RIBLSARIXXXX")).not_to be_valid
      end
    end
  end
end
