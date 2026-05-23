# frozen_string_literal: true

require "test_helper"

class BosniaAndHerzegovinaBankAccountTest < ActiveSupport::TestCase
  self.described_class = BosniaAndHerzegovinaBankAccount


  context_ BosniaAndHerzegovinaBankAccount do
  context_ "#bank_account_type" do
  test "returns BA" do
        expect(create(:bosnia_and_herzegovina_bank_account).bank_account_type).to eq("BA")
      end
    end

  context_ "#country" do
  test "returns BA" do
        expect(create(:bosnia_and_herzegovina_bank_account).country).to eq("BA")
      end
    end

  context_ "#currency" do
  test "returns bam" do
        expect(create(:bosnia_and_herzegovina_bank_account).currency).to eq("bam")
      end
    end

  context_ "#routing_number" do
  test "returns valid for 11 characters" do
        ba = create(:bosnia_and_herzegovina_bank_account)
        expect(ba).to be_valid
        expect(ba.routing_number).to eq("AAAABABAXXX")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:bosnia_and_herzegovina_bank_account, account_number_last_four: "6000").account_number_visual).to eq("BA******6000")
      end
    end
  end
end
