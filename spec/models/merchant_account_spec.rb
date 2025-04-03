# frozen_string_literal: true

require "spec_helper"

describe MerchantAccount do
  describe ".paypal" do
    it "returns records with the paypal charge processor id" do
      MerchantAccount.destroy_all
      create(:merchant_account)
      create(:merchant_account_paypal, charge_processor_id: BraintreeChargeProcessor.charge_processor_id)
      paypal_merchant_account = create(:merchant_account_paypal)
      another_paypal_merchant_account = create(:merchant_account_paypal)

      result = described_class.paypal
      expect(result.size).to eq(2)
      expect(result).to include(paypal_merchant_account)
      expect(result).to include(another_paypal_merchant_account)
    end
  end

  describe ".stripe" do
    it "returns records with the stripe charge processor id" do
      MerchantAccount.destroy_all
      stripe_merchant_account = create(:merchant_account)
      another_stripe_merchant_account = create(:merchant_account)
      create(:merchant_account_paypal, charge_processor_id: BraintreeChargeProcessor.charge_processor_id)
      create(:merchant_account_paypal)

      result = described_class.stripe
      expect(result.size).to eq(2)
      expect(result).to include(stripe_merchant_account)
      expect(result).to include(another_stripe_merchant_account)
    end
  end

  it "validates uniqueness of charge_processor_merchant_id when charge processor is stripe and is not a stripe connect account" do
    create(:merchant_account_paypal, charge_processor_merchant_id: "ABC")
    paypal_ma = build(:merchant_account_paypal, charge_processor_merchant_id: "ABC")

    expect(paypal_ma.valid?).to be(true)

    create(:merchant_account, charge_processor_merchant_id: "DEF")
    stripe_ma = build(:merchant_account, charge_processor_merchant_id: "DEF")

    expect(stripe_ma.valid?).to be(false)
    expect(stripe_ma.errors[:charge_processor_merchant_id].first).to match(/already connected/)

    create(:merchant_account_stripe_connect, charge_processor_merchant_id: "GHI")
    stripe_connect_ma = build(:merchant_account_stripe_connect, charge_processor_merchant_id: "GHI")

    expect(stripe_connect_ma.valid?).to be(true)
  end

  describe "#is_managed_by_gumroad?" do
    it "returns true if user_id is not assigned" do
      merchant_account = create(:merchant_account, user_id: nil)
      expect(merchant_account.is_managed_by_gumroad?).to be(true)
    end

    it "returns false if user_id is assigned" do
      merchant_account = create(:merchant_account)
      expect(merchant_account.user_id).not_to be(nil)
      expect(merchant_account.is_managed_by_gumroad?).to be(false)
    end
  end

  describe "#can_accept_charges?" do
    it "returns true if account is not from one of the cross-border payouts countries" do
      merchant_account = create(:merchant_account)
      expect(merchant_account.can_accept_charges?).to be(true)
    end

    it "returns false if account is from one of the cross-border payouts countries" do
      merchant_account = create(:merchant_account, country: "TH")
      expect(merchant_account.can_accept_charges?).to be(false)
    end
  end

  describe "#delete_charge_processor_account!", :vcr do
    it "marks the merchant account as deleted and clears the meta field" do
      merchant_account = create(:merchant_account_stripe)
      merchant_account.meta = { stripe_connect: false }
      merchant_account.save!

      merchant_account.delete_charge_processor_account!

      expect(merchant_account.reload.alive?).to be false
      expect(merchant_account.charge_processor_alive?).to be false
      expect(merchant_account.meta).to be_blank
    end

    it "marks the merchant account as deleted and does not clear the meta field if it is a stripe connect account" do
      merchant_account = create(:merchant_account_stripe_connect)

      merchant_account.delete_charge_processor_account!

      expect(merchant_account.reload.alive?).to be false
      expect(merchant_account.charge_processor_alive?).to be false
      expect(merchant_account.meta).to be_present
    end
  end

  describe "#is_a_paypal_connect_account?" do
    it "returns true if charge_processor_id is PayPal otherwise false" do
      merchant_account = create(:merchant_account, charge_processor_id: PaypalChargeProcessor.charge_processor_id)
      expect(merchant_account.is_a_paypal_connect_account?).to be(true)

      merchant_account = create(:merchant_account, charge_processor_id: StripeChargeProcessor.charge_processor_id)
      expect(merchant_account.is_a_paypal_connect_account?).to be(false)

      merchant_account = create(:merchant_account, charge_processor_id: BraintreeChargeProcessor.charge_processor_id)
      expect(merchant_account.is_a_paypal_connect_account?).to be(false)
    end
  end

  describe "#holder_of_funds" do
    it "returns the holder of funds for a known charge processor" do
      merchant_account = create(:merchant_account, charge_processor_id: ChargeProcessor.charge_processor_ids.first)
      expect(merchant_account.holder_of_funds).to eq(HolderOfFunds::STRIPE)
    end

    it "returns gumroad for a removed charge processor" do
      merchant_account = create(:merchant_account, user: nil, charge_processor_id: "google_play")
      expect(merchant_account.holder_of_funds).to eq(HolderOfFunds::GUMROAD)
    end
  end
end
