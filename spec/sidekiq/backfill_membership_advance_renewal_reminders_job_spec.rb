# frozen_string_literal: true

require "spec_helper"

describe BackfillMembershipAdvanceRenewalRemindersJob do
  it "runs the backfill with the rollout cutoff" do
    expect(Onetime::BackfillMembershipAdvanceRenewalReminders).to receive(:process).with(rollout_finished_at: described_class::ROLLOUT_FINISHED_AT)

    described_class.new.perform
  end
end
