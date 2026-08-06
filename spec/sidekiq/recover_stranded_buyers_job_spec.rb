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
      expect(message).to include("ERROR boom@example.com — block survived clear")
      expect(message).to include("would recover 1 of 2")
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
end
