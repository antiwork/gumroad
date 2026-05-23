# frozen_string_literal: true

require "test_helper"

class MonacoBankAccountTest < ActiveSupport::TestCase
  self.described_class = MonacoBankAccount


  context_ MonacoBankAccount do
  context_ "#bank_account_type" do
  test "returns MC" do
        expect(create(:monaco_bank_account).bank_account_type).to eq("MC")
      end
    end

  context_ "#country" do
  test "returns MC" do
        expect(create(:monaco_bank_account).country).to eq("MC")
      end
    end

  context_ "#currency" do
  test "returns eur" do
        expect(create(:monaco_bank_account).currency).to eq("eur")
      end
    end

  context_ "#account_number_visual" do
  test "returns the visual account number" do
        expect(create(:monaco_bank_account, account_number_last_four: "6789").account_number_visual).to eq("MC******6789")
      end
    end
  end
end
