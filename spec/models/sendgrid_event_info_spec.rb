# frozen_string_literal: true

require "spec_helper"

describe SendgridEventInfo do
  describe "#for_abandoned_cart_email?" do
    it "returns true when the mailer class is CustomerMailer and the mailer method is abandoned_cart" do
      event_json = { "mailer_class" => "CustomerMailer", "mailer_method" => "abandoned_cart" }
      sendgrid_event_info = SendgridEventInfo.new(event_json)
      expect(sendgrid_event_info.for_abandoned_cart_email?).to be(true)
    end

    it "returns false when the mailer class is not CustomerMailer" do
      event_json = { "mailer_class" => "CreatorContactingCustomersMailer", "mailer_method" => "abandoned_cart" }
      sendgrid_event_info = SendgridEventInfo.new(event_json)
      expect(sendgrid_event_info.for_abandoned_cart_email?).to be(false)
    end

    it "returns false when the mailer method is not abandoned_cart" do
      event_json = { "mailer_class" => "CustomerMailer", "mailer_method" => "purchase_installment" }
      sendgrid_event_info = SendgridEventInfo.new(event_json)
      expect(sendgrid_event_info.for_abandoned_cart_email?).to be(false)
    end
  end
end
