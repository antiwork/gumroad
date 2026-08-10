# frozen_string_literal: true

describe DispatchPendingWorkflowInstallmentScheduleIntentsJob do
  def create_intent(processed_at: nil, dispatch_expires_at: nil)
    WorkflowInstallmentScheduleIntent.create!(
      token: SecureRandom.uuid,
      installment_id: 1,
      rule_version: 1,
      cutoff_reference_time: Time.current,
      processed_at:,
      dispatch_expires_at:
    )
  end

  it "dispatches available intents and skips active leases and processed intents" do
    pending = create_intent
    expired = create_intent(dispatch_expires_at: 1.minute.ago)
    create_intent(dispatch_expires_at: 1.minute.from_now)
    create_intent(processed_at: Time.current)
    expect(WorkflowInstallmentScheduleIntent).to receive(:enqueue).with(pending.token)
    expect(WorkflowInstallmentScheduleIntent).to receive(:enqueue).with(expired.token)

    described_class.new.perform
  end
end
