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
      allow_any_instance_of(HelperUserInfoService).to receive(:user_info).and_return({
                                                                                       user: nil,
                                                                                       account_infos: [],
                                                                                       purchase_infos: [],
                                                                                       recent_purchase: nil,
                                                                                     })
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

    context "when the event is for a new Stripe fraud email" do
      it "triggers BlockStripeSuspectedFraudulentPaymentsWorker and skips UnblockEmailService" do
        @payload["email_from"] = BlockStripeSuspectedFraudulentPaymentsWorker::STRIPE_EMAIL_SENDER
        @payload["subject"] = BlockStripeSuspectedFraudulentPaymentsWorker::POSSIBLE_CONVERSATION_SUBJECTS.sample

        expect_any_instance_of(BlockStripeSuspectedFraudulentPaymentsWorker).to receive(:perform).with(
          @payload["conversation_id"],
          @payload["email_from"],
          @payload["body"]
        )
        expect_any_instance_of(Helper::UnblockEmailService).not_to receive(:process)

        described_class.new.perform(@event, @payload)
      end
    end
  end
end
