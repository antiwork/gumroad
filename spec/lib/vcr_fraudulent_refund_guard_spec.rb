# frozen_string_literal: true

require "spec_helper"

describe "VCR live fraudulent refund guard" do
  it "refuses a recordable Stripe refund with reason=fraudulent" do
    VCR.use_cassette("vcr_fraudulent_refund_guard", record: :all) do
      expect do
        Stripe::Refund.create(charge: "ch_x", reason: "fraudulent")
      end.to raise_error(/Refusing a live Stripe refund/)
    end
  ensure
    FileUtils.rm_f(Rails.root.join("spec/support/fixtures/vcr_cassettes/vcr_fraudulent_refund_guard.yml"))
  end
end
