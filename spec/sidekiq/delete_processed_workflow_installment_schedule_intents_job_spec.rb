# frozen_string_literal: true

describe DeleteProcessedWorkflowInstallmentScheduleIntentsJob do
  def create_intent(processed_at:, **attributes)
    WorkflowInstallmentScheduleIntent.create!(
      {
        token: SecureRandom.uuid,
        installment_id: 1,
        rule_version: 1,
        cutoff_reference_time: Time.current,
        processed_at:
      }.merge(attributes)
    )
  end

  it "deletes only processed intents outside the retry window" do
    old = create_intent(processed_at: 31.days.ago)
    recent = create_intent(processed_at: 29.days.ago)
    pending = create_intent(processed_at: nil)
    leased = create_intent(processed_at: nil, dispatch_token: SecureRandom.uuid, dispatch_expires_at: 1.minute.from_now)

    described_class.new.perform

    expect(WorkflowInstallmentScheduleIntent.find_by(id: old.id)).to be_nil
    expect(WorkflowInstallmentScheduleIntent.where(id: [recent.id, pending.id, leased.id]).count).to eq(3)
  end
end
