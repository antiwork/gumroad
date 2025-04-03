# frozen_string_literal: true

require "spec_helper"

describe FightDisputesJob do
  let!(:dispute_evidence) { create(:dispute_evidence, seller_contacted_at: nil) }
  let!(:dispute_evidence_not_ready) { create(:dispute_evidence) }
  let!(:dispute_evidence_resolved) { create(:dispute_evidence, seller_contacted_at: nil, resolved_at: Time.current, resolution: "submitted") }

  describe "#perform" do
    it "performs the job" do
      described_class.new.perform

      expect(FightDisputeJob).to have_enqueued_sidekiq_job(dispute_evidence.dispute.id)
      expect(FightDisputeJob).not_to have_enqueued_sidekiq_job(dispute_evidence_not_ready.dispute.id)
      expect(FightDisputeJob).not_to have_enqueued_sidekiq_job(dispute_evidence_resolved.dispute.id)
    end
  end
end
