# frozen_string_literal: true

require "spec_helper"

describe User::FeatureStatus, ".no_payout_rail_in_compliance_country?" do
  let(:seller) { create(:user) }

  def set_country(name)
    seller.alive_user_compliance_info&.mark_deleted!
    create(:user_compliance_info_empty, user: seller, country: name)
    seller.reload
  end

  it "is true for a country with neither a native rail nor a PayPal receiving rail" do
    set_country("Syria")

    expect(seller.native_payouts_supported?).to be(false)
    expect(seller.no_payout_rail_in_compliance_country?).to be(true)
  end

  it "is true for the other known zero-rail countries" do
    ["Zambia", "Russia", "Iraq"].each do |country|
      set_country(country)
      expect(seller.no_payout_rail_in_compliance_country?).to be(true), "expected #{country} to have no rail"
    end
  end

  it "is false where we support bank payouts" do
    set_country("United States")

    expect(seller.no_payout_rail_in_compliance_country?).to be(false)
  end

  it "is false where PayPal can pay into an account even though we have no bank rail" do
    set_country("Honduras")

    expect(seller.native_payouts_supported?).to be(false)
    expect(seller.no_payout_rail_in_compliance_country?).to be(false)
  end

  it "is false with no compliance info at all, rather than claiming the seller cannot be paid" do
    expect(seller.alive_user_compliance_info).to be_nil
    expect(seller.no_payout_rail_in_compliance_country?).to be(false)
  end

  it "is false once a bank account exists, whatever the country says" do
    set_country("Syria")
    allow(seller).to receive(:active_bank_account).and_return(build(:ach_account))

    expect(seller.no_payout_rail_in_compliance_country?).to be(false)
  end

  # The predicate is messaging-only. A seller in a zero-rail country is still payable through a
  # PayPal account registered elsewhere, so it must not have quietly become a gate.
  it "does not revoke the PayPal payout option it warns about" do
    set_country("Syria")

    expect(seller.can_setup_paypal_payouts?).to be(true)
  end

  describe "PaypalPayoutProcessor::PAYOUT_RECEIVING_COUNTRY_CODES" do
    it "holds alpha2 codes only, with no duplicates" do
      codes = PaypalPayoutProcessor::PAYOUT_RECEIVING_COUNTRY_CODES

      expect(codes).to all(match(/\A[A-Z]{2}\z/))
      expect(codes.uniq).to eq(codes)
    end

    # Zambia is the case that produced the seller-facing copy in the first place: PayPal operates
    # there, so a list keyed on "PayPal is available" would wrongly mark it payable.
    it "excludes Zambia and includes the US" do
      expect(PaypalPayoutProcessor::PAYOUT_RECEIVING_COUNTRY_CODES).not_to include("ZM")
      expect(PaypalPayoutProcessor::PAYOUT_RECEIVING_COUNTRY_CODES).to include("US")
    end

    it "never lists a comprehensively sanctioned country as payable" do
      %w[CU IR KP].each do |code|
        expect(PaypalPayoutProcessor::PAYOUT_RECEIVING_COUNTRY_CODES).not_to include(code)
      end
    end
  end
end
