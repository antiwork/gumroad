# frozen_string_literal: true

require "spec_helper"

describe HandleHelperEventWorker do
  include Rails.application.routes.url_helpers

  let!(:params) do
    {
      "event": "conversation.created",
      "payload": {
        "conversation_id": "6d389b441fcb17378effbdc4192ee69d",
        "email_id": "123",
        "email_from": "user@example.com",
        "subject": "Some subject",
        "body": "Some body"
      },
    }
  end

  before do
    @event = params[:event]
    @payload = params[:payload].as_json
  end

  describe "#perform" do
    it "triggers UnblockEmailService" do
      allow_any_instance_of(HelperUserInfoService).to receive(:recent_purchase).and_return(nil)
      expect_any_instance_of(Helper::UnblockEmailService).to receive(:process)
      expect_any_instance_of(Helper::UnblockEmailService).to receive(:replied?)
      described_class.new.perform(@event, @payload)
    end

    context "when event is invalid" do
      it "does not trigger UnblockEmailService" do
        expect_any_instance_of(Helper::UnblockEmailService).not_to receive(:process)
        @event = "invalid_event"
        described_class.new.perform(@event, @payload)
      end
    end

    context "when there is no email" do
      it "does not trigger UnblockEmailService" do
        expect_any_instance_of(Helper::UnblockEmailService).not_to receive(:process)
        @payload["email_from"] = nil
        described_class.new.perform(@event, @payload)
      end
    end

    context "when the email is an automated Stripe notification" do
      it "does not trigger UnblockEmailService" do
        expect_any_instance_of(HelperUserInfoService).not_to receive(:recent_purchase)
        expect_any_instance_of(Helper::UnblockEmailService).not_to receive(:process)
        @payload["email_from"] = described_class::STRIPE_NOTIFICATION_SENDER
        described_class.new.perform(@event, @payload)
      end
    end
  end
end
