# frozen_string_literal: true

require "spec_helper"

describe EmailSuppressionManager, :vcr do
  let(:email) { "sam@example.com" }

  describe "#unblock_email" do
    let(:lists) { [:bounces, :spam_reports] }

    it "scans all lists even if the email is found in one of the lists in between" do
      allow_any_instance_of(SendGrid::Client).to receive_message_chain(:bounces, :_, :delete, :status_code).and_return(204)

      lists.each do |list|
        expect_any_instance_of(SendGrid::Client).to receive_message_chain(list, :_, :delete, :status_code)
      end

      described_class.new(email).unblock_email
    end

    context "when suppressed email is found in any of the lists" do
      before do
        allow_any_instance_of(SendGrid::Client).to receive_message_chain(:spam_reports, :_, :delete, :status_code).and_return(204)
      end

      it "returns true" do
        expect(described_class.new(email).unblock_email).to eq(true)
      end
    end

    context "when suppressed email is not found in any list" do
      it "returns false" do
        expect(described_class.new(email).unblock_email).to eq(false)
      end
    end
  end

  describe "#reason_for_suppression" do
    it "returns bulleted list of reasons for suppression" do
      sample_suppression_response = [{
        created: 1683811050,
        email:,
        reason: "550 5.1.1 Sample reason",
        status: "5.1.1"
      }]
      allow_any_instance_of(SendGrid::Client).to receive_message_chain(:bounces, :_, :get, :parsed_body).and_return(sample_suppression_response)

      expect(described_class.new(email).reasons_for_suppression).to include(gumroad: [{ list: :bounces, reason: "550 5.1.1 Sample reason" }])
    end

    context "when SendGrid response is not a array of hashes" do
      it "notifies Bugsnag" do
        allow_any_instance_of(SendGrid::Client).to receive_message_chain(:bounces, :_, :get, :parsed_body).and_return("sample")
        expect(Bugsnag).to receive(:notify).at_least(:once)

        described_class.new(email).reasons_for_suppression
      end
    end
  end
end
