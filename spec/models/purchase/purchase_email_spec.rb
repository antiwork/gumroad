# frozen_string_literal: true

require "spec_helper"

describe Purchase, "email normalization" do
  let(:purchase) { build(:purchase) }

  it "strips invisible format characters and surrounding whitespace, then downcases" do
    purchase.email = "\u200F Buyer@Example.COM \u00A0"
    purchase.valid?
    expect(purchase.email).to eq("buyer@example.com")
  end

  it "leaves a blank email blank so the validation still rejects it" do
    purchase.email = ""
    expect(purchase).not_to be_valid
    expect(purchase.email).to eq("")
  end
end
