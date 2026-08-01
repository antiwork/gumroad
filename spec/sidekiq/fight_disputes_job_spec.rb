# frozen_string_literal: true

require "spec_helper"

describe FightDisputesJob do
  # The window has elapsed: seller_contacted_at is old enough that hours_left is not positive.
  let!(:dispute_evidence) { create(:dispute_evidence, seller_contacted_at: 80.hours.ago) }
  let!(:dispute_evidence_not_ready) { create(:dispute_evidence) }
  let!(:dispute_evidence_resolved) { create(:dispute_evidence, seller_contacted_at: 80.hours.ago, resolved_at: Time.current, resolution: "submitted") }

  describe "#perform" do
    it "performs the job" do
      described_class.new.perform

      expect(FightDisputeJob).to have_enqueued_sidekiq_job(dispute_evidence.dispute.id)
      expect(FightDisputeJob).not_to have_enqueued_sidekiq_job(dispute_evidence_not_ready.dispute.id)
      expect(FightDisputeJob).not_to have_enqueued_sidekiq_job(dispute_evidence_resolved.dispute.id)
    end

    context "when the seller submitted early, inside their window" do
      # hours_left_to_submit_evidence now reports 0 for a spent submission slot
      # (gumroad-private#1612). This job must NOT read it: to the scheduler a spent slot is not an
      # expired window, and treating it as one would forward a seller's evidence hours early.
      let!(:dispute_evidence_submitted_early) do
        create(:dispute_evidence, seller_contacted_at: 2.hours.ago, seller_submitted_at: 1.hour.ago)
      end

      it "still waits for the window to close before forwarding" do
        expect(dispute_evidence_submitted_early.hours_left_to_submit_evidence).to eq(0)

        described_class.new.perform

        expect(FightDisputeJob).not_to have_enqueued_sidekiq_job(dispute_evidence_submitted_early.dispute.id)
      end
    end

    context "when the dispute has reached a terminal state" do
      let!(:dispute_evidence_lost) { create(:dispute_evidence, seller_contacted_at: 80.hours.ago) }
      let!(:dispute_evidence_won) { create(:dispute_evidence, seller_contacted_at: 80.hours.ago) }

      before do
        dispute_evidence_lost.dispute.update_column(:state, "lost")
        dispute_evidence_won.dispute.update_column(:state, "won")
      end

      it "does not enqueue FightDisputeJob for the terminal-state disputes" do
        described_class.new.perform

        expect(FightDisputeJob).not_to have_enqueued_sidekiq_job(dispute_evidence_lost.dispute.id)
        expect(FightDisputeJob).not_to have_enqueued_sidekiq_job(dispute_evidence_won.dispute.id)
      end
    end

    context "when the seller was never asked for evidence" do
      let!(:dispute_evidence_never_announced) { create(:dispute_evidence, seller_contacted_at: nil) }

      it "leaves it to CreateMissingDisputeEvidenceJob rather than submitting unasked" do
        # hours_left_to_submit_evidence returns 0 while seller_contacted_at is NULL, so an
        # unannounced row reads exactly like one whose window has elapsed.
        described_class.new.perform

        expect(FightDisputeJob.jobs.map { _1["args"] }).not_to include([dispute_evidence_never_announced.dispute.id])
      end
    end
  end
end
