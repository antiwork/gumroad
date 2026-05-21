# frozen_string_literal: true

require "spec_helper"

describe Onetime::ResolveStuckDisputeEvidence do
  describe ".process" do
    let!(:stuck_lost) do
      evidence = create(:dispute_evidence)
      evidence.dispute.update_column(:state, "lost")
      evidence
    end

    let!(:stuck_won) do
      evidence = create(:dispute_evidence)
      evidence.dispute.update_column(:state, "won")
      evidence
    end

    let!(:still_active) do
      create(:dispute_evidence)
    end

    let!(:already_resolved) do
      evidence = create(:dispute_evidence,
                        resolved_at: Time.current,
                        resolution: DisputeEvidence::RESOLUTION_SUBMITTED)
      evidence.dispute.update_column(:state, "lost")
      evidence
    end

    it "resolves only unresolved evidence whose dispute reached a terminal state" do
      described_class.process

      expect(stuck_lost.reload.resolved?).to eq(true)
      expect(stuck_lost.resolution).to eq(DisputeEvidence::RESOLUTION_REJECTED)
      expect(stuck_lost.error_message).to include("state=lost")

      expect(stuck_won.reload.resolved?).to eq(true)
      expect(stuck_won.resolution).to eq(DisputeEvidence::RESOLUTION_REJECTED)
      expect(stuck_won.error_message).to include("state=won")

      expect(still_active.reload.resolved?).to eq(false)

      expect(already_resolved.reload.resolution).to eq(DisputeEvidence::RESOLUTION_SUBMITTED)
    end
  end
end
