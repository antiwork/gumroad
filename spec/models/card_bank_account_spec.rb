# frozen_string_literal: true

require "spec_helper"

describe CardBankAccount, :vcr do
  it "only allows debit cards" do
    card_bank_account = create(:card_bank_account)
    expect(card_bank_account.credit_card.funding_type).to eq(ChargeableFundingType::DEBIT)
    expect(card_bank_account.valid?).to be(true)

    card = card_bank_account.credit_card
    card.funding_type = ChargeableFundingType::CREDIT
    card.save!

    expect(card_bank_account.valid?).to be(false)
    expect(card_bank_account.errors[:base].first).to eq("Your payout card must be a US debit card.")
  end

  it "only allows cards from the US" do
    card_bank_account = create(:card_bank_account)
    expect(card_bank_account.credit_card.card_country).to eq(Compliance::Countries::USA.alpha2)
    expect(card_bank_account.valid?).to be(true)

    card = card_bank_account.credit_card
    card.card_country = Compliance::Countries::BRA.alpha2
    card.save!

    expect(card_bank_account.valid?).to be(false)
    expect(card_bank_account.errors[:base].first).to eq("Your payout card must be a US debit card.")
  end

  it "disallows creating records with banned cards" do
    %w[5860 0559].each do |card_last_4|
      card_bank_account = build(:card_bank_account)
      card = card_bank_account.credit_card
      card.visual = "**** **** **** #{card_last_4}"
      expect(card_bank_account.valid?).to be(false)
      expect(card_bank_account.errors[:base].first).to eq("Your payout card must be a US debit card.")
    end
  end

  it "allows marking the records with banned cards as deleted" do
    %w[5860 0559].each do |card_last_4|
      card_bank_account = create(:card_bank_account)
      card = card_bank_account.credit_card
      card.visual = "**** **** **** #{card_last_4}"
      card.save!
      card_bank_account.mark_deleted!
      expect(card_bank_account.reload.deleted_at).to_not be_nil
    end
  end

  describe "#bank_account_type" do
    it "returns 'CARD'" do
      expect(create(:card_bank_account).bank_account_type).to eq("CARD")
    end
  end

  describe "#routing_number" do
    it "returns the capitalized card type" do
      expect(create(:card_bank_account).routing_number).to eq("Visa")
    end
  end

  describe "#account_number_visual" do
    it "returns the card's visual value" do
      expect(create(:card_bank_account).account_number_visual).to eq("**** **** **** 5556")
    end
  end

  describe "#account_number" do
    it "returns the card's visual value" do
      expect(create(:card_bank_account).account_number).to eq("**** **** **** 5556")
    end
  end

  describe "#account_number_last_four" do
    it "returns the last 4 digits of the card" do
      expect(create(:card_bank_account).account_number_last_four).to eq("5556")
    end
  end

  describe "#account_holder_full_name" do
    it "returns the card's visual value" do
      expect(create(:card_bank_account).account_holder_full_name).to eq("**** **** **** 5556")
    end
  end

  describe "#country" do
    it "returns the country code for the US" do
      expect(create(:card_bank_account).country).to eq(Compliance::Countries::USA.alpha2)
    end
  end

  describe "#currency" do
    it "returns the currency for the US" do
      expect(create(:card_bank_account).currency).to eq(Currency::USD)
    end
  end
end
