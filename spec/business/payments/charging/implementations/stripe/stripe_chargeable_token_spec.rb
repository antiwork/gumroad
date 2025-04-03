# frozen_string_literal: true

require "spec_helper"
require "business/payments/charging/chargeable_protocol"
require "business/payments/charging/implementations/stripe/stripe_chargeable_common_shared_examples"

describe StripeChargeableToken, :vcr do
  let(:number) { "4242 4242 4242 4242" }
  let(:expiry_month) { 12 }
  let(:expiry_year) { 2050 }
  let(:cvc) { "123" }
  let(:zip_code) { "12345" }
  let(:token) { Stripe::Token.create(card: { number:, exp_month: expiry_month, exp_year: expiry_year, cvc:, address_zip: zip_code }) }
  let(:token_id) { token.id }
  let(:chargeable) { StripeChargeableToken.new(token_id, zip_code, product_permalink: "xx") }
  let(:user) { create(:user) }

  it_behaves_like "a chargeable"

  include_examples "stripe chargeable common"

  describe "#prepare!" do
    it "retrieves token details from stripe" do
      expect(Stripe::Token).to receive(:retrieve).with(token_id).and_call_original
      chargeable.prepare!
    end
  end

  describe "#reusable_token!" do
    it "uses stripe to get a reusable token" do
      expect(Stripe::Customer)
        .to receive(:create)
        .with(hash_including(card: token_id,
                             description: user.id.to_s,
                             email: user.email))
        .and_return(id: "cus_testcustomer")
      expect(chargeable.reusable_token!(user)).to eq "cus_testcustomer"
    end

    it "fetches the customer's payment sources" do
      expect(Stripe::Customer).to receive(:create).with(hash_including(expand: %w[sources])).and_call_original
      chargeable.reusable_token!(user)
      expect(chargeable.card).to be_present
    end
  end

  describe "#visual" do
    it "calls ChargeableVisual to build a visual" do
      expect(ChargeableVisual).to receive(:build_visual).with("4242", 16).and_call_original
      chargeable.prepare!
      expect(chargeable.visual).to eq("**** **** **** 4242")
    end
  end
end
