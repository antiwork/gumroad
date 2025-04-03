# frozen_string_literal: true

require "spec_helper"

describe PaypalOrderRefund do
  describe ".new" do
    it "sets attributes correctly" do
      refund_response_double = double
      allow(refund_response_double).to receive(:id).and_return("ExampleID")

      order_refund = described_class.new(refund_response_double, "SampleCaptureId")
      expect(order_refund).to have_attributes(charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                                              charge_id: "SampleCaptureId", id: "ExampleID")
    end
  end
end
