# frozen_string_literal: true

require "spec_helper"

describe Helper::Client do
  let(:helper) { Helper::Client.new }
  let(:conversation_id) { "123456" }
  let(:timestamp) { DateTime.current.to_i }

  describe "#create_hmac_digest" do
    let(:secret_key) { "secret_key" }

    before do
      allow(GlobalConfig).to receive(:get).with("HELPER_WIDGET_SECRET").and_return(secret_key)
    end

    context "when payload is query params" do
      it "creates a digest from url-encoded payload" do
        params = { key: "value", timestamp: }
        expected_digest = OpenSSL::HMAC.digest(OpenSSL::Digest.new("sha256"), secret_key, params.to_query)

        expect(helper.create_hmac_digest(params:)).to eq(expected_digest)
      end
    end

    context "when payload is JSON" do
      it "creates a digest from JSON string" do
        json = { key: "value", timestamp: }
        expected_digest = OpenSSL::HMAC.digest(OpenSSL::Digest.new("sha256"), secret_key, json.to_json)

        expect(helper.create_hmac_digest(json:)).to eq(expected_digest)
      end
    end

    context "when both params and json are provided" do
      it "raises an error" do
        params = { key: "value", timestamp: }
        json = { another_key: "another_value", timestamp: }

        expect { helper.create_hmac_digest(params:, json:) }.to raise_error(RuntimeError, "Either params or json must be provided, but not both")
      end
    end

    context "when neither params nor json are provided" do
      it "raises an error" do
        expect { helper.create_hmac_digest }.to raise_error(RuntimeError, "Either params or json must be provided, but not both")
      end
    end
  end

  describe "#close_conversation" do
    it "sends a PATCH request to close the conversation" do
      stub_request(:patch, "https://api.helper.ai/api/v1/mailboxes/gumroad/conversations/#{conversation_id}/")
        .with(
          body: hash_including(status: "closed", timestamp: instance_of(Integer)),
          headers: { "Content-Type" => "application/json" }
        )
        .to_return(status: 200)

      expect(helper.close_conversation(conversation_id:)).to be true
    end

    context "when the request fails" do
      it "notifies Bugsnag" do
        stub_request(:patch, "https://api.helper.ai/api/v1/mailboxes/gumroad/conversations/#{conversation_id}/")
          .with(
            body: hash_including(status: "closed", timestamp: instance_of(Integer)),
            headers: { "Content-Type" => "application/json" }
          )
          .to_return(status: 422)

        expect(Bugsnag).to receive(:notify).with("Helper error: could not close conversation", conversation_id:)
        expect(helper.close_conversation(conversation_id:)).to be false
      end
    end
  end

  describe "#send_reply" do
    let(:message) { "Test reply message" }

    it "sends a POST request to send a reply" do
      stub_request(:post, "https://api.helper.ai/api/v1/mailboxes/gumroad/conversations/#{conversation_id}/emails/")
        .to_return(status: 200)

      expect(helper.send_reply(conversation_id:, message:)).to be true
    end

    it "sends a POST request to send a draft" do
      stub_request(:post, "https://api.helper.ai/api/v1/mailboxes/gumroad/conversations/#{conversation_id}/emails/")
        .with(body: hash_including(message:, draft: true, timestamp: instance_of(Integer)))
        .to_return(status: 200)

      expect(helper.send_reply(conversation_id:, message:, draft: true)).to be true
    end

    it "handles optional response_to" do
      response_to = "previous_message_id"
      stub_request(:post, "https://api.helper.ai/api/v1/mailboxes/gumroad/conversations/#{conversation_id}/emails/")
        .with(body: hash_including(response_to:, timestamp: instance_of(Integer)))
        .to_return(status: 200)

      expect(helper.send_reply(conversation_id:, message:, response_to:)).to be true
    end

    context "when the request fails" do
      it "notifies Bugsnag" do
        stub_request(:post, "https://api.helper.ai/api/v1/mailboxes/gumroad/conversations/#{conversation_id}/emails/")
          .to_return(status: 422)

        expect(Bugsnag).to receive(:notify).with("Helper error: could not send reply", conversation_id:, message:)
        expect(helper.send_reply(conversation_id:, message:)).to be false
      end
    end
  end

  describe "#add_note" do
    let(:message) { "Test note message" }

    it "sends a POST request to add a note" do
      stub_request(:post, "https://api.helper.ai/api/v1/mailboxes/gumroad/conversations/#{conversation_id}/notes/")
        .with(body: hash_including(message: message, timestamp: instance_of(Integer)))
        .to_return(status: 200)

      expect(helper.add_note(conversation_id:, message:)).to be true
    end

    context "when the request fails" do
      it "notifies Bugsnag" do
        stub_request(:post, "https://api.helper.ai/api/v1/mailboxes/gumroad/conversations/#{conversation_id}/notes/")
          .to_return(status: 422)

        expect(Bugsnag).to receive(:notify).with("Helper error: could not add note", conversation_id:, message:)
        expect(helper.add_note(conversation_id:, message:)).to be false
      end
    end
  end
end
