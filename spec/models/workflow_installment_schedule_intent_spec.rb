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

  it "leaves dispatch failures for the pending intent job" do
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

  it "releases its claim when middleware cancels the enqueue" do
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
end
