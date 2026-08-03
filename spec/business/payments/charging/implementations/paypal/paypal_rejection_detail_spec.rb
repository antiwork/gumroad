# frozen_string_literal: true

require "spec_helper"

describe PaypalChargeProcessor, ".build_paypal_rejection" do
  # PayPal's SDK hands back a parsed body of OpenStruct-ish nodes, so the response shape is
  # what these fake, not the HTTP call.
  def api_response(name:, details: nil)
    OpenStruct.new(result: OpenStruct.new(name:, details:))
  end

  def detail(issue: nil, description: nil)
    OpenStruct.new(issue:, description:)
  end

  describe "the issue string carried onto the error" do
    it "is PayPal's own issue when the response names one" do
      response = api_response(name: "UNPROCESSABLE_ENTITY", details: [detail(issue: "COMPLIANCE_VIOLATION")])

      error = described_class.build_paypal_rejection(ChargeProcessorInvalidRequestError, "msg", response)

      expect(error).to be_a(ChargeProcessorInvalidRequestError)
      expect(error.processor_error_code).to eq("COMPLIANCE_VIOLATION")
    end

    it "falls back to the response name when PayPal sends no details" do
      response = api_response(name: "INSTRUMENT_DECLINED")

      error = described_class.build_paypal_rejection(ChargeProcessorInvalidRequestError, "msg", response)

      expect(error.processor_error_code).to eq("INSTRUMENT_DECLINED")
    end

    it "is nil rather than raising when the response carries neither" do
      response = api_response(name: nil, details: [])

      error = described_class.build_paypal_rejection(ChargeProcessorInvalidRequestError, "msg", response)

      expect(error.processor_error_code).to be_nil
    end

    it "does not raise when the response has no result at all" do
      expect do
        described_class.build_paypal_rejection(ChargeProcessorInvalidRequestError, "msg", OpenStruct.new)
      end.not_to raise_error
    end
  end

  it "leaves the named error classes constructed exactly as before" do
    response = api_response(name: "UNPROCESSABLE_ENTITY", details: [detail(issue: "PAYEE_ACCOUNT_RESTRICTED")])

    error = described_class.build_paypal_rejection(ChargeProcessorPayeeAccountRestrictedError, "msg", response)

    expect(error).to be_a(ChargeProcessorPayeeAccountRestrictedError)
    expect(error.message).to eq("msg")
  end

  it "keeps the message the caller built" do
    response = api_response(name: "UNPROCESSABLE_ENTITY", details: [detail(issue: "COMPLIANCE_VIOLATION")])

    error = described_class.build_paypal_rejection(ChargeProcessorInvalidRequestError, "Failed PayPal create order: |nope", response)

    expect(error.message).to eq("Failed PayPal create order: |nope")
  end

  describe ".paypal_rejection_description" do
    it "returns the first detail's description" do
      response = api_response(name: "UNPROCESSABLE_ENTITY", details: [detail(description: "The requested action could not be performed.")])

      expect(described_class.paypal_rejection_description(response)).to eq("The requested action could not be performed.")
    end

    it "returns nil when there is no details array" do
      expect(described_class.paypal_rejection_description(api_response(name: "INTERNAL_ERROR"))).to be_nil
    end
  end
end
