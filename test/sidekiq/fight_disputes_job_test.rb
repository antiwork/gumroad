# frozen_string_literal: true

require "test_helper"

class FightDisputesJobTest < ActiveSupport::TestCase
  self.described_class = FightDisputesJob



  context_ FightDisputesJob do
    let!(:dispute_evidence) { create(:dispute_evidence, seller_contacted_at: nil) }
    let!(:dispute_evidence_not_ready) { create(:dispute_evidence) }
    let!(:dispute_evidence_resolved) { create(:dispute_evidence, seller_contacted_at: nil, resolved_at: Time.current, resolution: "submitted") }

  context_ "#perform" do
  test "performs the job" do
        described_class.new.perform

        expect(FightDisputeJob).to have_enqueued_sidekiq_job(dispute_evidence.dispute.id)
        expect(FightDisputeJob).not_to have_enqueued_sidekiq_job(dispute_evidence_not_ready.dispute.id)
        expect(FightDisputeJob).not_to have_enqueued_sidekiq_job(dispute_evidence_resolved.dispute.id)
      end

  context_ "when the dispute has reached a terminal state" do
        let!(:dispute_evidence_lost) { create(:dispute_evidence, seller_contacted_at: nil) }
        let!(:dispute_evidence_won) { create(:dispute_evidence, seller_contacted_at: nil) }

        before do
          dispute_evidence_lost.dispute.update_column(:state, "lost")
          dispute_evidence_won.dispute.update_column(:state, "won")
        end

  test "does not enqueue FightDisputeJob for the terminal-state disputes" do
          described_class.new.perform

          expect(FightDisputeJob).not_to have_enqueued_sidekiq_job(dispute_evidence_lost.dispute.id)
          expect(FightDisputeJob).not_to have_enqueued_sidekiq_job(dispute_evidence_won.dispute.id)
        end
      end
    end
  end
end
