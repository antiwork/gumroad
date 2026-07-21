# frozen_string_literal: true

require "spec_helper"

describe TransientEmailFailureClassifier do
  def classify(reason, event_type: EmailEventInfo::EVENT_BOUNCED)
    described_class.new(event_type:, reason:).classify
  end

  describe "#classify" do
    # Representative reason strings observed on our SendGrid suppression
    # lists (see the deliverability ops runbook taxonomy), plus common RFC
    # 5321/3463 wordings.
    TRANSIENT_REASONS = [
      "421 4.7.0 Try again later, closing connection",
      "450 4.2.1 The user you are trying to contact is receiving mail too quickly. Please resend your message at a later time.",
      "451 4.7.1 Greylisting in action, please come back later",
      "451 Temporary local problem - please try later",
      "452 4.2.2 Mailbox full",
      "552 5.2.2 mailbox full",
      "552 5.2.2 The email account that you tried to reach is over quota",
      "error dialing remote address: dial tcp 216.198.53.209:25: i/o timeout",
      "read tcp 108.179.163.36:44262: read: connection timed out",
      "connection refused",
      "421 4.3.2 System resources unavailable, closing connection",
      "resources temporarily unavailable",
      "Temporarily deferred due to unexpected volume or user complaints",
    ].freeze

    HARD_REASONS = [
      "550 5.1.1 The email account that you tried to reach does not exist",
      "550 5.1.1 <someone@gmail.com>: Recipient address rejected: User unknown in virtual mailbox table",
      "550 No such user here",
      "550 5.5.0 Requested action not taken: no such mailbox",
      "550 Unknown recipient",
      "550 Address is not configured to receive emails",
      "553 5.1.2 Bad mailbox name: the address is syntactically invalid",
      "Domain example-nonexistent.com not found (NXDOMAIN)",
      "550 Host or domain name not found",
      "Invalid Recipient - https://community.mimecast.com/docs/DOC-1369#550",
    ].freeze

    UNKNOWN_REASONS = [
      "Bounced Address",             # SendGrid "dropped" event shorthand — no SMTP detail to classify on
      "some entirely novel refusal wording",
      "",
      nil,
    ].freeze

    TRANSIENT_REASONS.each do |reason|
      it "classifies #{reason.inspect} as :transient" do
        expect(classify(reason)).to eq(:transient)
      end
    end

    HARD_REASONS.each do |reason|
      it "classifies #{reason.inspect} as :hard" do
        expect(classify(reason)).to eq(:hard)
      end
    end

    UNKNOWN_REASONS.each do |reason|
      it "classifies #{reason.inspect} as :unknown (fail-closed, no retry)" do
        expect(classify(reason)).to eq(:unknown)
      end
    end

    it "prefers :hard when a reason contains both hard and transient signatures" do
      # A hard signature must always win so we can't be tricked into
      # retrying a dead address by a "try again later" suffix.
      expect(classify("550 5.1.1 user unknown, try again later")).to eq(:hard)
    end
  end

  describe "#transient?" do
    it "returns true only for transient classifications" do
      expect(described_class.new(event_type: EmailEventInfo::EVENT_BOUNCED, reason: "452 4.2.2 Mailbox full").transient?).to eq(true)
      expect(described_class.new(event_type: EmailEventInfo::EVENT_BOUNCED, reason: "550 user unknown").transient?).to eq(false)
      expect(described_class.new(event_type: EmailEventInfo::EVENT_BOUNCED, reason: nil).transient?).to eq(false)
    end
  end
end
