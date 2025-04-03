# frozen_string_literal: true

require "spec_helper"

describe StripeApplePayDomain do
  it "validates presence of attributes" do
    record = StripeApplePayDomain.create()
    expect(record.errors.messages).to eq(
      user: ["can't be blank"],
      domain: ["can't be blank"],
      stripe_id: ["can't be blank"],
    )
  end
end
