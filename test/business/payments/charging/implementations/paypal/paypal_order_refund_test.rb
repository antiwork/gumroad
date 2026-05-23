# frozen_string_literal: true

require "test_helper"

class PaypalOrderRefundTest < ActiveSupport::TestCase
  self.described_class = PaypalOrderRefund



  context_ PaypalOrderRefund do
  context_ ".new" do
  test "sets attributes correctly" do
        refund_response_double = double
        allow(refund_response_double).to receive(:id).and_return("ExampleID")

        order_refund = described_class.new(refund_response_double, "SampleCaptureId")
        expect(order_refund).to have_attributes(charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                                                charge_id: "SampleCaptureId", id: "ExampleID")
      end
    end
  end
end
