# frozen_string_literal: true

require "test_helper"

class SendgridEventInfoTest < ActiveSupport::TestCase
  self.described_class = SendgridEventInfo



  context_ SendgridEventInfo do
  context_ "#for_abandoned_cart_email?" do
  test "returns true when the mailer class is CustomerMailer and the mailer method is abandoned_cart" do
        event_json = { "mailer_class" => "CustomerMailer", "mailer_method" => "abandoned_cart" }
        sendgrid_event_info = SendgridEventInfo.new(event_json)
        expect(sendgrid_event_info.for_abandoned_cart_email?).to be(true)
      end

  test "returns false when the mailer class is not CustomerMailer" do
        event_json = { "mailer_class" => "CreatorContactingCustomersMailer", "mailer_method" => "abandoned_cart" }
        sendgrid_event_info = SendgridEventInfo.new(event_json)
        expect(sendgrid_event_info.for_abandoned_cart_email?).to be(false)
      end

  test "returns false when the mailer method is not abandoned_cart" do
        event_json = { "mailer_class" => "CustomerMailer", "mailer_method" => "purchase_installment" }
        sendgrid_event_info = SendgridEventInfo.new(event_json)
        expect(sendgrid_event_info.for_abandoned_cart_email?).to be(false)
      end
    end
  end
end
