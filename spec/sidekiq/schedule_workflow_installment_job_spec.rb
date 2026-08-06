# frozen_string_literal: true

describe ScheduleWorkflowInstallmentJob do
  let(:workflow) { create(:audience_workflow, published_at: 1.day.ago) }
  let(:installment) { create(:workflow_installment, workflow:, seller: workflow.seller, published_at: workflow.published_at) }
  let(:rule) { installment.installment_rule }
  let(:cutoff_reference_time) { Time.current.change(usec: 0) }

  it "schedules the installment after the expected rule version commits" do
    expect_any_instance_of(Workflow).to receive(:schedule_installment)
      .with(
        kind_of(Installment),
        old_delayed_delivery_time: 1.hour.to_i,
        cutoff_reference_time:,
        reschedule_on_stale: true
      )

    described_class.new.perform(installment.id, rule.version, 1.hour.to_i, cutoff_reference_time.iso8601)
  end

  it "retries while the expected rule version is not visible" do
    expect do
      described_class.new.perform(installment.id, rule.version + 1, 1.hour.to_i, cutoff_reference_time.iso8601)
    end.to raise_error(ScheduleWorkflowInstallmentJob::RuleNotCommittedError)
  end

  it "preserves the recipient window from a superseded rule version" do
    expect_any_instance_of(Workflow).to receive(:schedule_installment)
      .with(
        kind_of(Installment),
        old_delayed_delivery_time: 1.hour.to_i,
        cutoff_reference_time:,
        reschedule_on_stale: true
      )

    described_class.new.perform(installment.id, rule.version - 1, 1.hour.to_i, cutoff_reference_time.iso8601)
  end

  it "retries while a new installment is not visible" do
    expect do
      described_class.new.perform(-1, 1, nil, cutoff_reference_time.iso8601)
    end.to raise_error(ScheduleWorkflowInstallmentJob::RuleNotCommittedError)
  end
end
