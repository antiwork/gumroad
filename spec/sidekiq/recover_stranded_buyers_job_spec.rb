# frozen_string_literal: true

require "spec_helper"

describe RecoverStrandedBuyersJob do
  let(:candidate) do
    {
      email: "stranded@example.com",
      purchaser_external_id: "ext-123",
      settled_purchases: 5,
      blocked_at: 2.months.ago,
      block_type: PlatformBlock::TYPES[:browser_guid],
      failed_at: 1.day.ago,
      attempts: 3,
    }
  end

  def recovery_result(verdict, reason, cleared: [], skipped: [], dry_run: true)
    Risk::StrandedBuyerRecoveryService::Result.new(
      verdict:, reason:, attribution: nil, cleared:, skipped:, dry_run:
    )
  end

  before do
    allow(InternalNotificationWorker).to receive(:perform_async)
  end

  it "does nothing when the scan finds nobody" do
    allow(Risk::StrandedBuyerScanService).to receive(:call).and_return(stranded: [], truncated: false)

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "dry-runs every candidate while the flag is off and says so in the report" do
    allow(Risk::StrandedBuyerScanService).to receive(:call).and_return(stranded: [candidate], truncated: false)
    allow(Risk::StrandedBuyerRecoveryService).to receive(:call)
      .and_return(recovery_result(:cleared, :single_decline_auto_block, cleared: [PlatformBlock.new(object_type: PlatformBlock::TYPES[:email], object_value: candidate[:email])]))

    described_class.new.perform

    expect(Risk::StrandedBuyerRecoveryService).to have_received(:call)
      .with(email: candidate[:email], user_external_id: candidate[:purchaser_external_id], dry_run: true)
    expect(InternalNotificationWorker).to have_received(:perform_async) do |room, sender, message|
      expect(room).to eq("risk")
      expect(sender).to eq("Stranded buyer recovery")
      expect(message).to include("DRY RUN")
      expect(message).to include("would recover 1 of 1")
    end
  end

  it "clears live when auto_recover_stranded_buyers is active" do
    Feature.activate(:auto_recover_stranded_buyers)
    allow(Risk::StrandedBuyerScanService).to receive(:call).and_return(stranded: [candidate], truncated: false)
    allow(Risk::StrandedBuyerRecoveryService).to receive(:call)
      .and_return(recovery_result(:cleared, :single_decline_auto_block, dry_run: false))

    described_class.new.perform

    expect(Risk::StrandedBuyerRecoveryService).to have_received(:call)
      .with(email: candidate[:email], user_external_id: candidate[:purchaser_external_id], dry_run: false)
    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("Recovered 1 of 1")
      expect(message).not_to include("DRY RUN")
    end
  ensure
    Feature.deactivate(:auto_recover_stranded_buyers)
  end

  it "names escalated buyers in the report so a human sees the authored blocks" do
    escalated = candidate.merge(email: "authored@example.com", purchaser_external_id: nil)
    allow(Risk::StrandedBuyerScanService).to receive(:call).and_return(stranded: [escalated], truncated: false)
    allow(Risk::StrandedBuyerRecoveryService).to receive(:call)
      .and_return(recovery_result(:escalate, :authored_block))

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("ESCALATE authored@example.com")
    end
  end

  it "continues past a candidate whose clear raises, reporting the error" do
    failing = candidate.merge(email: "boom@example.com")
    ok = candidate.merge(email: "fine@example.com")
    allow(Risk::StrandedBuyerScanService).to receive(:call).and_return(stranded: [failing, ok], truncated: false)
    allow(Risk::StrandedBuyerRecoveryService).to receive(:call)
      .with(hash_including(email: "boom@example.com"))
      .and_raise(Risk::StrandedBuyerRecoveryService::VerificationFailedError, "block survived clear")
    allow(Risk::StrandedBuyerRecoveryService).to receive(:call)
      .with(hash_including(email: "fine@example.com"))
      .and_return(recovery_result(:cleared, :single_decline_auto_block))

    described_class.new.perform

    expect(Risk::StrandedBuyerRecoveryService).to have_received(:call).twice
    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("ERROR boom@example.com — Risk::StrandedBuyerRecoveryService::VerificationFailedError: block survived clear")
      expect(message).to include("would recover 1 of 2")
    end
  end

  # The rescue is deliberately StandardError-wide: an uncaught deadlock or RecordInvalid on
  # candidate #3 would otherwise skip the rest of the run AND the report.
  it "survives an error the service did not classify" do
    allow(Risk::StrandedBuyerScanService).to receive(:call).and_return(stranded: [candidate], truncated: false)
    allow(Risk::StrandedBuyerRecoveryService).to receive(:call).and_raise(ActiveRecord::Deadlocked, "lock wait")

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("ERROR stranded@example.com — ActiveRecord::Deadlocked: lock wait")
    end
  end

  it "reports every count from the outcomes, not just the cleared line" do
    outcomes = [
      candidate.merge(email: "cleared@example.com"),
      candidate.merge(email: "skipped@example.com"),
      candidate.merge(email: "noop@example.com"),
    ]
    allow(Risk::StrandedBuyerScanService).to receive(:call).and_return(stranded: outcomes, truncated: false)
    cleared_blocks = [PlatformBlock.new, PlatformBlock.new]
    withheld_blocks = [[PlatformBlock.new, :shared_identifier_needs_human_review]]
    allow(Risk::StrandedBuyerRecoveryService).to receive(:call)
      .with(hash_including(email: "cleared@example.com"))
      .and_return(recovery_result(:cleared, :single_decline_auto_block, cleared: cleared_blocks, skipped: withheld_blocks))
    allow(Risk::StrandedBuyerRecoveryService).to receive(:call)
      .with(hash_including(email: "skipped@example.com"))
      .and_return(recovery_result(:skip, :no_clean_payment_history))
    allow(Risk::StrandedBuyerRecoveryService).to receive(:call)
      .with(hash_including(email: "noop@example.com"))
      .and_return(recovery_result(:noop, :no_active_blocks))

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("would recover 1 of 3")
      expect(message).to include("(3 candidates total)")
      expect(message).to include("2 blocks cleared")
      expect(message).to include("1 withheld for a human")
      expect(message).to include("1 skipped")
      expect(message).to include("1 no-ops")
    end
  end

  it "bounds one run to MAX_RECOVERIES_PER_RUN candidates" do
    many = (described_class::MAX_RECOVERIES_PER_RUN + 5).times.map do |i|
      candidate.merge(email: "buyer#{i}@example.com")
    end
    allow(Risk::StrandedBuyerScanService).to receive(:call).and_return(stranded: many, truncated: false)
    allow(Risk::StrandedBuyerRecoveryService).to receive(:call)
      .and_return(recovery_result(:skip, :no_clean_payment_history))

    described_class.new.perform

    expect(Risk::StrandedBuyerRecoveryService).to have_received(:call).exactly(described_class::MAX_RECOVERIES_PER_RUN).times
  end

  # A dry run mutates nothing, so without rotation the same head-of-scan candidates would be
  # re-evaluated forever and the rest of the population never seen.
  it "rotates the window across days so every candidate is eventually processed" do
    many = (described_class::MAX_RECOVERIES_PER_RUN * 2).times.map do |i|
      candidate.merge(email: "buyer#{i}@example.com")
    end
    allow(Risk::StrandedBuyerScanService).to receive(:call).and_return(stranded: many, truncated: false)
    allow(Risk::StrandedBuyerRecoveryService).to receive(:call)
      .and_return(recovery_result(:skip, :no_clean_payment_history))

    seen = Set.new
    allow(Risk::StrandedBuyerRecoveryService).to receive(:call) do |email:, **|
      seen << email
      recovery_result(:skip, :no_clean_payment_history)
    end

    travel_to(Date.new(2026, 8, 6)) { described_class.new.perform }
    travel_to(Date.new(2026, 8, 7)) { described_class.new.perform }

    expect(seen.size).to eq(many.size)
  end

  it "is registered on the schedule so it actually runs" do
    schedule = YAML.load_file(Rails.root.join("config", "sidekiq_schedule.yml"))

    expect(schedule.values.map { |entry| entry["class"] }).to include(described_class.name)
  end

  # Every example above stubs the worker, and InternalNotificationMailer#notify returns silently
  # when the room has no recipient — which would leave the job permanently dark with all specs green.
  it "sends to a room that resolves to a real recipient" do
    mail = InternalNotificationMailer.notify(room_name: "risk", sender: "spec", message_text: "hello")

    expect(mail.to).to be_present
  end
end
