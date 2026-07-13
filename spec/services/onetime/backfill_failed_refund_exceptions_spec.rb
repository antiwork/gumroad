# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillFailedRefundExceptions do
  describe ".process" do
    it "creates pending exception records for failed refunds that lack one" do
      failed_refund = create(:refund, status: "failed")
      reversed_refund = create(:refund, status: "failed")
      reversed_refund.balance_reversed_on_failure = true
      reversed_refund.save!
      create(:refund, status: "succeeded")
      already_tracked = create(:refund, status: "failed")
      create(:failed_refund_exception, refund: already_tracked)

      expect { described_class.process }.to change(FailedRefundException, :count).by(2)

      expect(FailedRefundException.find_by(refund: failed_refund)).to have_attributes(
        state: "pending",
        owner: FailedRefundException.default_owner,
        notification_room: "payments",
        balance_reversed: false,
        notification_sent_at: nil
      )
      expect(FailedRefundException.find_by(refund: reversed_refund).balance_reversed).to eq(true)
    end

    it "is idempotent across repeated runs" do
      create(:refund, status: "failed")

      described_class.process
      expect { described_class.process }.not_to change(FailedRefundException, :count)
    end
  end
end
