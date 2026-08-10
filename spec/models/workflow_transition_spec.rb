# frozen_string_literal: true

require "spec_helper"

describe Workflow do
  let(:workflow) { create(:workflow) }
  let!(:installment) { create(:workflow_installment, workflow:, seller: workflow.seller, is_for_new_customers_of_workflow: false) }
  let(:rule) { installment.installment_rule }

  before do
    allow_any_instance_of(User).to receive(:eligible_to_send_emails?).and_return(true)
  end

  it "locks the workflow and advances the rule version before publishing" do
    previous_version = rule.version
    expect(workflow).to receive(:lock!).and_call_original
    expect_any_instance_of(Installment).to receive(:publish!).and_wrap_original do |method, **kwargs|
      expect(InstallmentRule.cached_version(installment.id)).to eq(previous_version + 1)
      method.call(**kwargs)
    end

    expect(workflow.publish!).to be(true)

    expect(installment.reload).to be_published
    expect(rule.reload.version).to eq(previous_version + 1)
    token = ScheduleWorkflowInstallmentJob.jobs.sole.fetch("args").sole
    expect(WorkflowInstallmentScheduleIntent.find_by!(token:)).to have_attributes(
      installment_id: installment.id,
      rule_version: rule.version,
      cutoff_reference_time: workflow.published_at,
      expected_published_at: workflow.published_at
    )
    expect(SendWorkflowPostEmailsJob.jobs).to be_empty
  end

  it "rolls back a publish schedule intent with its transaction" do
    Workflow.transaction do
      workflow.publish!
      expect(WorkflowInstallmentScheduleIntent.count).to eq(1)
      expect(ScheduleWorkflowInstallmentJob.jobs).to be_empty
      raise ActiveRecord::Rollback
    end

    expect(workflow.reload.published_at).to be_nil
    expect(WorkflowInstallmentScheduleIntent.count).to eq(0)
    expect(ScheduleWorkflowInstallmentJob.jobs).to be_empty
  end

  it "keeps a committed publish intent when the fast path returns no job ID" do
    allow(ScheduleWorkflowInstallmentJob).to receive(:perform_async).and_return(nil)

    workflow.publish!

    expect(workflow.reload.published_at).to be_present
    expect(WorkflowInstallmentScheduleIntent.pending.sole.installment_id).to eq(installment.id)
  end

  it "hands the saved cutoff and minimum rule version to the recipient fanout" do
    published_at = 1.day.ago
    workflow.update!(published_at:)
    installment.update!(published_at:)
    cutoff_reference_time = Time.current.change(usec: 0)
    schedule_intent_token = SecureRandom.uuid
    schedule_intent_fanout_token = SecureRandom.uuid

    result = workflow.schedule_installment(
      installment,
      old_delayed_delivery_time: 6.hours.to_i,
      cutoff_reference_time:,
      minimum_rule_version: rule.version,
      schedule_intent_token:,
      schedule_intent_fanout_token:
    )

    expect(result).to eq(:enqueued)
    expect(SendWorkflowPostEmailsJob).to have_enqueued_sidekiq_job(
      installment.id,
      (cutoff_reference_time - 6.hours).iso8601,
      false,
      rule.version,
      schedule_intent_token,
      schedule_intent_fanout_token
    )
  end

  it "returns not_enqueued when middleware cancels the recipient fanout" do
    published_at = 1.day.ago
    workflow.update!(published_at:)
    installment.update!(published_at:)
    allow(SendWorkflowPostEmailsJob).to receive(:perform_async).and_return(nil)

    expect(workflow.schedule_installment(installment)).to eq(:not_enqueued)
  end

  it "hands the minimum rule version to the cancellation fanout" do
    published_at = 1.day.ago
    workflow.update!(
      published_at:,
      workflow_trigger: Workflow::MEMBER_CANCELLATION_WORKFLOW_TRIGGER,
      send_to_past_customers: true
    )
    installment.update!(published_at:)
    schedule_intent_token = SecureRandom.uuid
    schedule_intent_fanout_token = SecureRandom.uuid

    result = workflow.schedule_installment(
      installment,
      minimum_rule_version: rule.version,
      schedule_intent_token:,
      schedule_intent_fanout_token:
    )

    expect(result).to eq(:enqueued)
    expect(SendWorkflowEmailsToPastCanceledMembersJob).to have_enqueued_sidekiq_job(
      installment.id,
      nil,
      nil,
      rule.version,
      schedule_intent_token,
      schedule_intent_fanout_token
    )
  end

  it "locks the workflow and advances the rule version before unpublishing" do
    workflow.update!(published_at: 1.day.ago)
    installment.update!(published_at: workflow.published_at)
    previous_version = rule.version
    expect(workflow).to receive(:lock!).and_call_original
    expect_any_instance_of(Installment).to receive(:unpublish!).and_wrap_original do |method|
      expect(InstallmentRule.cached_version(installment.id)).to eq(previous_version + 1)
      method.call
    end

    workflow.unpublish!

    expect(installment.reload).not_to be_published
    expect(rule.reload.version).to eq(previous_version + 1)
  end

  it "locks the workflow and advances the rule version before deletion" do
    previous_version = rule.version
    expect(workflow).to receive(:lock!).and_call_original
    expect_any_instance_of(Installment).to receive(:mark_deleted!).and_wrap_original do |method|
      expect(InstallmentRule.cached_version(installment.id)).to eq(previous_version + 1)
      method.call
    end

    workflow.mark_deleted!

    expect(workflow).to be_deleted
    expect(installment.reload).to be_deleted
    expect(rule.reload).to be_deleted
    expect(rule.version).to eq(previous_version + 1)
  end
end
