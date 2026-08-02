# frozen_string_literal: true

require "spec_helper"

describe TransientEmailFailureClassifier do
  def classify(reason)
    described_class.new(reason:).classify
  end

  describe "#classify" do
    # Representative reason strings observed on our SendGrid suppression
    # lists (see the deliverability ops runbook taxonomy), plus common RFC
    # 5321/3463 wordings.
    transient_reasons = [
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

    hard_reasons = [
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

    unknown_reasons = [
      "Bounced Address",             # SendGrid "dropped" event shorthand — no SMTP detail to classify on
      "some entirely novel refusal wording",
      "",
      nil,
    ].freeze

    transient_reasons.each do |reason|
      it "classifies #{reason.inspect} as :transient" do
        expect(classify(reason)).to eq(:transient)
      end
    end

    hard_reasons.each do |reason|
      it "classifies #{reason.inspect} as :hard" do
        expect(classify(reason)).to eq(:hard)
      end
    end

    unknown_reasons.each do |reason|
      it "classifies #{reason.inspect} as :unknown (fail-closed, no retry)" do
        expect(classify(reason)).to eq(:unknown)
      end
    end

    it "prefers :hard when a reason contains both hard and transient signatures" do
      # A hard signature must always win so we can't be tricked into
      # retrying a dead address by a "try again later" suffix.
      expect(classify("550 5.1.1 user unknown, try again later")).to eq(:hard)
    end

    # The 4xx pattern is anchored to the leading status code. Unanchored, a 4xx-looking number
    # anywhere in a permanent 5xx reason — Microsoft's AS() diagnostic, a URL, a policy ref —
    # promoted it to :transient, which is the one direction this classifier must never err in:
    # the address gets un-suppressed and we resend into a permanent block.
    [
      "550 5.7.606 Access denied, banned sending IP; AS(425)",
      "550 blocked: see https://help.example.com/errors/404",
      "550 5.7.1 Message rejected due to content policy (ref 451)",
    ].each do |reason|
      it "does not treat #{reason.inspect} as transient on an incidental 4xx-shaped token" do
        expect(classify(reason)).to_not eq(:transient)
      end
    end
  end

  describe "#transient?" do
    it "returns true only for transient classifications" do
      expect(described_class.new(reason: "452 4.2.2 Mailbox full").transient?).to eq(true)
      expect(described_class.new(reason: "550 user unknown").transient?).to eq(false)
      expect(described_class.new(reason: nil).transient?).to eq(false)
    end
  end
end
