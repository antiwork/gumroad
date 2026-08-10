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

  it "requires callers to hold a database transaction before enqueueing" do
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

  it "leaves dispatch failures for the pending-intent job" do
    intent = create_intent
    allow(ScheduleWorkflowInstallmentJob).to receive(:perform_async).and_raise("Redis is unavailable")
    expect(Rails.logger).to receive(:error).with(/Redis is unavailable/)

    expect(described_class.enqueue(intent.token)).to be_nil
    expect(intent.reload.dispatch_expires_at).to be_present
    expect(described_class.dispatchable).not_to include(intent)
  end

  it "claims an intent before enqueueing its scheduler" do
    intent = create_intent
    expect(ScheduleWorkflowInstallmentJob).to receive(:perform_async).with(intent.token).once.and_return("jid")

    expect(described_class.enqueue(intent.token)).to eq("jid")
    expect(described_class.enqueue(intent.token)).to be_nil

    expect(intent.reload.dispatch_token).to be_present
    expect(intent.dispatch_expires_at).to be > Time.current
  end

  it "releases its claim when client middleware cancels the enqueue" do
    intent = create_intent
    allow(ScheduleWorkflowInstallmentJob).to receive(:perform_async).and_return(nil)

    expect(described_class.enqueue(intent.token)).to be_nil

    expect(intent.reload.dispatch_token).to be_nil
    expect(intent.dispatch_expires_at).to be_nil
    expect(described_class.dispatchable).to include(intent)
  end

  it "reclaims an expired dispatch lease" do
    intent = create_intent(dispatch_token: SecureRandom.uuid, dispatch_expires_at: 1.minute.ago)
    expect(ScheduleWorkflowInstallmentJob).to receive(:perform_async).with(intent.token).and_return("jid")

    expect(described_class.enqueue(intent.token)).to eq("jid")

    expect(intent.reload.dispatch_expires_at).to be > Time.current
  end

  it "marks only a pending matching token as processed" do
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

  it "renews a matching fanout lease" do
    intent = create_intent
    fanout_token = intent.claim_fanout!

    expect(described_class.begin_fanout(intent_token: intent.token, fanout_token:)).to be(true)

    expect(intent.reload.fanout_expires_at).to be > 119.minutes.from_now
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
