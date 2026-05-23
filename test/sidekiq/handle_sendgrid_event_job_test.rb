# frozen_string_literal: true

require "test_helper"

class HandleSendgridEventJobTest < ActiveSupport::TestCase
  self.described_class = HandleSendgridEventJob


  context_ HandleSendgridEventJob do
  context_ ".perform" do
  context_ "when the event type is not supported" do
        let(:params) do
          {
            "_json" => [
              {
                "event" => "processed",
                "type" => "CustomerMailer.receipt",
                "identifier" => "[1]"
              }
            ]
          }
        end

  test "does nothing" do
          expect(HandleEmailEventInfo::ForInstallmentEmail).not_to receive(:perform)
          expect(HandleEmailEventInfo::ForReceiptEmail).not_to receive(:perform)
          expect(HandleEmailEventInfo::ForAbandonedCartEmail).not_to receive(:perform)

          described_class.new.perform(params)
        end
      end

  context_ "when the event data is invalid" do
        let(:params) do
          {
            "_json" => [
              {
                "foo" => "bar",
              }
            ]
          }
        end

  test "does nothing" do
          expect(HandleEmailEventInfo::ForInstallmentEmail).not_to receive(:perform)
          expect(HandleEmailEventInfo::ForReceiptEmail).not_to receive(:perform)
          expect(HandleEmailEventInfo::ForAbandonedCartEmail).not_to receive(:perform)

          described_class.new.perform(params)
        end
      end

  test "handles events for abandoned cart emails" do
        params = { "_json" => [{ "event" => "delivered", "mailer_class" => "CustomerMailer", "mailer_method" => "abandoned_cart", "mailer_args" => "[3783, {\"5296\"=>[153758, 163413], \"5644\"=>[163413]}]" }] }

        expect(HandleEmailEventInfo::ForInstallmentEmail).not_to receive(:perform)
        expect(HandleEmailEventInfo::ForReceiptEmail).not_to receive(:perform)
        expect(HandleEmailEventInfo::ForAbandonedCartEmail).to receive(:perform).with(an_instance_of(SendgridEventInfo))

        described_class.new.perform(params)
      end
    end
  end
end
