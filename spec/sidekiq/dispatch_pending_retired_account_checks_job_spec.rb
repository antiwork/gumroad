# frozen_string_literal: true

require "spec_helper"

describe DispatchPendingRetiredAccountChecksJob do
  let(:seller) { create(:user) }
  let(:due_at) { (AlertOnRetiredManagedAccountActivityJob::SETTLEMENT_TAIL + described_class::RECOVERY_DELAY).ago }

  # A managed account the connect switch retired: the linker leaves the re-dispatch marker on it.
  def retire_account!(retired_at:, pending_at: retired_at)
    account = create(:merchant_account, user: seller, charge_processor_merchant_id: "acct_pending_#{SecureRandom.hex(4)}")
    account.update!(deleted_at: retired_at, retired_activity_check_pending_at: pending_at)
    account
  end

  before { allow(AlertOnRetiredManagedAccountActivityJob).to receive(:perform_async) }

  it "re-dispatches a retirement whose check is overdue" do
    account = retire_account!(retired_at: due_at - 1.hour)

    described_class.new.perform

    expect(AlertOnRetiredManagedAccountActivityJob).to have_received(:perform_async)
      .with(account.id, account.deleted_at.utc.iso8601)
  end

  # The scheduled check may still be queued; dispatching it twice would alert twice.
  it "leaves a retirement whose own check is not yet due" do
    retire_account!(retired_at: 1.day.ago)

    described_class.new.perform

    expect(AlertOnRetiredManagedAccountActivityJob).not_to have_received(:perform_async)
  end

  it "leaves a retirement whose check has already run alone" do
    retire_account!(retired_at: due_at - 1.hour, pending_at: nil)

    described_class.new.perform

    expect(AlertOnRetiredManagedAccountActivityJob).not_to have_received(:perform_async)
  end

  # The marker is set only while a check is owed, so a retirement far past its tail that is still
  # marked is exactly the lost-enqueue case this job exists for.
  it "re-dispatches a retirement whose check is still owed long after its tail" do
    account = retire_account!(retired_at: 30.days.ago)

    described_class.new.perform

    expect(AlertOnRetiredManagedAccountActivityJob).to have_received(:perform_async)
      .with(account.id, account.deleted_at.utc.iso8601)
  end

  it "leaves a managed account the switch never retired alone" do
    create(:merchant_account, user: seller, charge_processor_merchant_id: "acct_never_retired")

    described_class.new.perform

    expect(AlertOnRetiredManagedAccountActivityJob).not_to have_received(:perform_async)
  end
end
