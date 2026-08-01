# frozen_string_literal: true

require "spec_helper"

describe DisputeEvidenceDueSoonReminderJob do
  describe "#perform" do
    let(:dispute_evidence) { create(:dispute_evidence) }

    it "enqueues the reminder email" do
      expect do
        described_class.new.perform(dispute_evidence.dispute.id)
      end.to have_enqueued_mail(ContactingCreatorMailer, :chargeback_evidence_due_soon).with(dispute_evidence.dispute.id)
    end
  end
end
