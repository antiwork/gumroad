# frozen_string_literal: true

require "spec_helper"

describe PaypalChargeable do
  let(:paypal_chargeable) { PaypalChargeable.new("B-38D505255T217912K", "paypal-gr-integspecs@gumroad.com", "US") }

  it "returns customer paypal email for #email, billing agreement id for #fingerprint, and nil #last4" do
    expect(paypal_chargeable.fingerprint).to eq("B-38D505255T217912K")
    expect(paypal_chargeable.email).to eq("paypal-gr-integspecs@gumroad.com")
    expect(paypal_chargeable.last4).to be_nil
  end

  it "returns customer paypal email for #visual, and nil for #number_length, #expiry_month and #expiry_year" do
    expect(paypal_chargeable.visual).to eq("paypal-gr-integspecs@gumroad.com")
    expect(paypal_chargeable.number_length).to be_nil
    expect(paypal_chargeable.expiry_month).to be_nil
    expect(paypal_chargeable.expiry_year).to be_nil
  end

  it "returns correct country and nil #zip_code" do
    expect(paypal_chargeable.zip_code).to be_nil
    expect(paypal_chargeable.country).to eq("US")
  end

  it "returns billing agreement id for #reusable_token!" do
    reusable_token = paypal_chargeable.reusable_token!(nil)
    expect(reusable_token).to eq("B-38D505255T217912K")
  end

  it "returns paypal for #charge_processor_id" do
    expect(paypal_chargeable.charge_processor_id).to eq("paypal")
  end
end
