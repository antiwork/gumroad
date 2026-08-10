# frozen_string_literal: true

describe WorkflowInstallmentScheduleIntent do
  def create_intent(**attributes)
    described_class.create!(
      {
        token: SecureRandom.uuid,
        installment_id: 1,
        rule_version: 1,
        cutoff_reference_time: Time.current
      }.merge(attributes)
    )
  end

  it "requires a database transaction before enqueueing" do
    connection = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter, transaction_open?: false)
    allow(described_class).to receive(:connection).and_return(connection)

    expect do
      described_class.enqueue!(
        installment: instance_double(Installment, id: 1),
        rule_version: 1,
        old_delayed_delivery_time: nil,
        cutoff_reference_time: Time.current
      )
    end.to raise_error(described_class::EnqueueError, "A database transaction is required")
  end

  it "does not persist a claim when the scheduler enqueue raises" do
    intent = create_intent
    allow(ScheduleWorkflowInstallmentJob).to receive(:perform_async).and_raise("Redis is unavailable")
    expect(Rails.logger).to receive(:error).with(/Redis is unavailable/)

    expect(described_class.enqueue(intent.token)).to be_nil
    expect(intent.reload.dispatch_token).to be_nil
    expect(intent.dispatch_expires_at).to be_nil
    expect(described_class.dispatchable).to include(intent)
  end

  it "contains a dispatch query failure" do
    intent = create_intent
    allow(described_class).to receive(:dispatchable).and_raise("database is unavailable")
    expect(Rails.logger).to receive(:error).with(/database is unavailable/)

    expect(described_class.enqueue(intent.token)).to be_nil
  end

  it "does not persist a claim when middleware cancels the enqueue" do
    intent = create_intent
    allow(ScheduleWorkflowInstallmentJob).to receive(:perform_async).and_return(nil)
    expect(Rails.logger).to receive(:error).with(/scheduler job was not enqueued/i)

    expect(described_class.enqueue(intent.token)).to be_nil
    expect(intent.reload.dispatch_token).to be_nil
    expect(intent.dispatch_expires_at).to be_nil
    expect(described_class.dispatchable).to include(intent)
  end

  it "records a claim after enqueueing its scheduler" do
    intent = create_intent
    expect(ScheduleWorkflowInstallmentJob).to receive(:perform_async).with(intent.token).once.and_return("jid")

    expect(described_class.enqueue(intent.token)).to eq("jid")
    expect(described_class.enqueue(intent.token)).to be_nil

    expect(intent.reload.dispatch_token).to be_present
    expect(intent.dispatch_expires_at).to be > Time.current
  end

  it "reclaims an expired dispatch lease" do
    intent = create_intent(dispatch_token: SecureRandom.uuid, dispatch_expires_at: 1.minute.ago)
    expect(ScheduleWorkflowInstallmentJob).to receive(:perform_async).with(intent.token).and_return("jid")

    expect(described_class.enqueue(intent.token)).to eq("jid")

    expect(intent.reload.dispatch_expires_at).to be > Time.current
  end

  it "marks only the matching fanout owner as processed" do
    fanout_token = SecureRandom.uuid
    intent = create_intent(
      dispatch_token: SecureRandom.uuid,
      dispatch_expires_at: 1.minute.from_now,
      fanout_token:,
      fanout_expires_at: 1.minute.from_now
    )

    described_class.mark_processed(intent.token, fanout_token:)

    expect(intent.reload.processed_at).to be_present
    expect(intent.dispatch_token).to be_nil
    expect(intent.dispatch_expires_at).to be_nil
    expect(intent.fanout_token).to be_nil
    expect(intent.fanout_expires_at).to be_nil
  end

  it "does not complete an intent without its fanout owner" do
    intent = create_intent(fanout_token: SecureRandom.uuid, fanout_expires_at: 1.minute.from_now)

    described_class.mark_processed(intent.token, fanout_token: nil)

    expect(intent.reload.processed_at).to be_nil
  end

  it "does not let a stale fanout complete another owner" do
    intent = create_intent(fanout_token: SecureRandom.uuid, fanout_expires_at: 1.minute.from_now)

    described_class.mark_processed(intent.token, fanout_token: SecureRandom.uuid)

    expect(intent.reload.processed_at).to be_nil
  end

  it "claims one fanout until its lease expires" do
    intent = create_intent

    first_token = intent.claim_fanout!
    expect(first_token).to be_present
    expect(intent.claim_fanout!).to be_nil

    intent.update!(fanout_expires_at: 1.minute.ago)
    second_token = intent.claim_fanout!
    expect(second_token).to be_present
    expect(second_token).not_to eq(first_token)
  end

  it "starts a matching fanout and renews its lease" do
    intent = create_intent
    fanout_token = intent.claim_fanout!

    expect(described_class.begin_fanout(intent_token: intent.token, fanout_token:)).to be(true)

    expect(intent.reload.fanout_expires_at).to be > 119.minutes.from_now
  end

  it "renews only the matching fanout owner" do
    intent = create_intent
    fanout_token = intent.claim_fanout!
    original_expiry = intent.fanout_expires_at

    travel 10.minutes do
      expect(
        described_class.renew_fanout(intent_token: intent.token, fanout_token: SecureRandom.uuid)
      ).to be(false)
      expect(intent.reload.fanout_expires_at).to eq(original_expiry)

      expect(described_class.renew_fanout(intent_token: intent.token, fanout_token:)).to be(true)
      expect(intent.reload.fanout_token).to eq(fanout_token)
      expect(intent.fanout_expires_at).to be > original_expiry
    end
  end

  it "keeps direct fanouts independent of intent leases" do
    expect(described_class.renew_fanout(intent_token: nil, fanout_token: nil)).to be(true)
  end

  it "lets an expired owner renew until another owner takes over" do
    intent = create_intent
    first_token = intent.claim_fanout!
    intent.update!(fanout_expires_at: 1.minute.ago)

    expect(described_class.renew_fanout(intent_token: intent.token, fanout_token: first_token)).to be(true)
    expect(intent.with_lock { intent.claim_fanout! }).to be_nil

    intent.update!(fanout_expires_at: 1.minute.ago)
    second_token = intent.claim_fanout!
    second_expiry = intent.fanout_expires_at

    expect(described_class.renew_fanout(intent_token: intent.token, fanout_token: first_token)).to be(false)
    expect(intent.reload.fanout_token).to eq(second_token)
    expect(intent.fanout_expires_at).to eq(second_expiry)
  end

  it "does not renew a processed intent" do
    intent = create_intent(processed_at: Time.current, fanout_token: SecureRandom.uuid)

    expect(
      described_class.renew_fanout(intent_token: intent.token, fanout_token: intent.fanout_token)
    ).to be(false)
  end

  it "rejects a stale fanout while another owner is active" do
    intent = create_intent
    current_token = intent.claim_fanout!

    expect(
      described_class.begin_fanout(intent_token: intent.token, fanout_token: SecureRandom.uuid)
    ).to be(false)
    expect(intent.reload.fanout_token).to eq(current_token)
  end

  it "lets a fetched fanout claim an expired lease" do
    intent = create_intent(fanout_token: SecureRandom.uuid, fanout_expires_at: 1.minute.ago)
    fetched_token = SecureRandom.uuid

    expect(described_class.begin_fanout(intent_token: intent.token, fanout_token: fetched_token)).to be(true)

    expect(intent.reload.fanout_token).to eq(fetched_token)
    expect(intent.fanout_expires_at).to be > 119.minutes.from_now
  end

  it "does not start a fanout for a processed intent" do
    intent = create_intent(processed_at: Time.current)

    expect(
      described_class.begin_fanout(intent_token: intent.token, fanout_token: SecureRandom.uuid)
    ).to be(false)
  end
end
