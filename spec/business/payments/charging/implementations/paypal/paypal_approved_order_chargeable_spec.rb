# frozen_string_literal: true

require "spec_helper"

describe PaypalApprovedOrderChargeable do
  let(:paypal_approved_order_chargeable) { PaypalApprovedOrderChargeable.new("9J862133JL8076730", "paypal-gr-integspecs@gumroad.com", "US") }

  it "returns customer paypal email for #email, paypal order id for #fingerprint, and nil #last4" do
    expect(paypal_approved_order_chargeable.fingerprint).to eq("9J862133JL8076730")
    expect(paypal_approved_order_chargeable.email).to eq("paypal-gr-integspecs@gumroad.com")
    expect(paypal_approved_order_chargeable.last4).to be_nil
  end

  it "returns customer paypal email for #visual, and nil for #number_length, #expiry_month and #expiry_year" do
    expect(paypal_approved_order_chargeable.visual).to eq("paypal-gr-integspecs@gumroad.com")
    expect(paypal_approved_order_chargeable.number_length).to be_nil
    expect(paypal_approved_order_chargeable.expiry_month).to be_nil
    expect(paypal_approved_order_chargeable.expiry_year).to be_nil
  end

  it "returns correct country and nil #zip_code" do
    expect(paypal_approved_order_chargeable.zip_code).to be_nil
    expect(paypal_approved_order_chargeable.country).to eq("US")
  end

  it "returns nil for #reusable_token!" do
    reusable_token = paypal_approved_order_chargeable.reusable_token!(123)
    expect(reusable_token).to be(nil)
  end

  it "returns paypal for #charge_processor_id" do
    expect(paypal_approved_order_chargeable.charge_processor_id).to eq("paypal")
  end
end
