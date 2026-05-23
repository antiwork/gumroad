# frozen_string_literal: true

require "test_helper"

class CardBankAccountTest < ActiveSupport::TestCase
  self.described_class = CardBankAccount
  self.rspec_metadata = { vcr: true }



  context_ CardBankAccount, :vcr do
  test "only allows debit cards" do
      card_bank_account = create(:card_bank_account)
      expect(card_bank_account.credit_card.funding_type).to eq(ChargeableFundingType::DEBIT)
      expect(card_bank_account.valid?).to be(true)

      card = card_bank_account.credit_card
      card.funding_type = ChargeableFundingType::CREDIT
      card.save!

      expect(card_bank_account.valid?).to be(false)
      expect(card_bank_account.errors[:base].first).to eq("Your payout card must be a US debit card.")
    end

  test "only allows cards from the US" do
      card_bank_account = create(:card_bank_account)
      expect(card_bank_account.credit_card.card_country).to eq(Compliance::Countries::USA.alpha2)
      expect(card_bank_account.valid?).to be(true)

      card = card_bank_account.credit_card
      card.card_country = Compliance::Countries::BRA.alpha2
      card.save!

      expect(card_bank_account.valid?).to be(false)
      expect(card_bank_account.errors[:base].first).to eq("Your payout card must be a US debit card.")
    end

  test "disallows creating records with banned cards" do
      %w[5860 0559].each do |card_last_4|
        card_bank_account = build(:card_bank_account)
        card = card_bank_account.credit_card
        card.visual = "**** **** **** #{card_last_4}"
        expect(card_bank_account.valid?).to be(false)
        expect(card_bank_account.errors[:base].first).to eq("Your payout card must be a US debit card.")
      end
    end

  test "allows marking the records with banned cards as deleted" do
      %w[5860 0559].each do |card_last_4|
        card_bank_account = create(:card_bank_account)
        card = card_bank_account.credit_card
        card.visual = "**** **** **** #{card_last_4}"
        card.save!
        card_bank_account.mark_deleted!
        expect(card_bank_account.reload.deleted_at).not_to be_nil
      end
    end

  context_ "#bank_account_type" do
  test "returns 'CARD'" do
        expect(create(:card_bank_account).bank_account_type).to eq("CARD")
      end
    end

  context_ "#routing_number" do
  test "returns the capitalized card type" do
        expect(create(:card_bank_account).routing_number).to eq("Visa")
      end
    end

  context_ "#account_number_visual" do
  test "returns the card's visual value" do
        expect(create(:card_bank_account).account_number_visual).to eq("**** **** **** 5556")
      end
    end

  context_ "#account_number" do
  test "returns the card's visual value" do
        expect(create(:card_bank_account).account_number).to eq("**** **** **** 5556")
      end
    end

  context_ "#account_number_last_four" do
  test "returns the last 4 digits of the card" do
        expect(create(:card_bank_account).account_number_last_four).to eq("5556")
      end
    end

  context_ "#account_holder_full_name" do
  test "returns the card's visual value" do
        expect(create(:card_bank_account).account_holder_full_name).to eq("**** **** **** 5556")
      end
    end

  context_ "#country" do
  test "returns the country code for the US" do
        expect(create(:card_bank_account).country).to eq(Compliance::Countries::USA.alpha2)
      end
    end

  context_ "#currency" do
  test "returns the currency for the US" do
        expect(create(:card_bank_account).currency).to eq(Currency::USD)
      end
    end
  end
end
