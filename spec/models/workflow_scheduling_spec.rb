# frozen_string_literal: true

require "spec_helper"

describe Workflow do
  describe "#mark_deleted!" do
    it "locks the workflow before deleting its installments" do
      workflow = create(:workflow)
      installment = create(:workflow_installment, workflow:, seller: workflow.seller)
      previous_rule_version = installment.installment_rule.version
      expect(workflow).to receive(:lock!).and_call_original
      expect_any_instance_of(Installment).to receive(:mark_deleted!).and_wrap_original do |method|
        expect(InstallmentRule.cached_version(installment.id)).to eq(previous_rule_version + 1)
        method.call
      end

      workflow.mark_deleted!

      expect(workflow).to be_deleted
      expect(installment.reload).to be_deleted
      expect(installment.installment_rule.reload).to be_deleted
      expect(installment.installment_rule.version).to eq(previous_rule_version + 1)
    end

    it "deletes an installment without a rule" do
      workflow = create(:workflow)
      installment = create(:workflow_installment, workflow:, seller: workflow.seller)
      installment.installment_rule.destroy!

      workflow.mark_deleted!

      expect(workflow.reload).to be_deleted
      expect(installment.reload).to be_deleted
    end
  end

  describe "publish transitions" do
    it "locks the workflow before publishing installments" do
      workflow = create(:workflow)
      installment = create(:workflow_installment, workflow:, seller: workflow.seller)
      allow_any_instance_of(User).to receive(:eligible_to_send_emails?).and_return(true)
      expect(workflow).to receive(:lock!).and_call_original

      workflow.publish!

      expect(installment.reload).to be_published
    end

    it "routes recipient scheduling through a visibility-retrying job" do
      workflow = create(:workflow)
      installment = create(:workflow_installment, workflow:, seller: workflow.seller)
      previous_rule_version = installment.installment_rule.version
      allow_any_instance_of(User).to receive(:eligible_to_send_emails?).and_return(true)
      expect_any_instance_of(Installment).to receive(:publish!).and_wrap_original do |method, **kwargs|
        expect(InstallmentRule.cached_version(installment.id)).to eq(previous_rule_version + 1)
        method.call(**kwargs)
      end

      workflow.publish!

      installment.reload
      expect(installment.installment_rule.version).to eq(previous_rule_version + 1)

      token = ScheduleWorkflowInstallmentJob.jobs.sole.fetch("args").sole
      intent = WorkflowInstallmentScheduleIntent.find_by!(token:)
      expect(intent).to have_attributes(
        installment_id: installment.id,
        rule_version: installment.installment_rule.version,
        old_delayed_delivery_time: nil,
        cutoff_reference_time: workflow.published_at,
        expected_published_at: workflow.published_at
      )
    end

    it "publishes an installment without a rule without scheduling it" do
      workflow = create(:workflow)
      installment = create(:workflow_installment, workflow:, seller: workflow.seller)
      installment.installment_rule.destroy!
      allow_any_instance_of(User).to receive(:eligible_to_send_emails?).and_return(true)

      workflow.publish!

      expect(workflow.reload.published_at).to be_present
      expect(installment.reload.published_at).to eq(workflow.published_at)
      expect(WorkflowInstallmentScheduleIntent.count).to eq(0)
      expect(ScheduleWorkflowInstallmentJob.jobs).to be_empty
    end

    it "does not keep an intent or enqueue a job if publication rolls back" do
      workflow = create(:workflow)
      installment = create(:workflow_installment, workflow:, seller: workflow.seller)
      allow_any_instance_of(User).to receive(:eligible_to_send_emails?).and_return(true)

      Workflow.transaction do
        workflow.publish!
        expect(WorkflowInstallmentScheduleIntent.count).to eq(1)
        expect(ScheduleWorkflowInstallmentJob.jobs).to be_empty
        raise ActiveRecord::Rollback
      end

      expect(workflow.reload.published_at).to be_nil
      expect(installment.reload.published_at).to be_nil
      expect(WorkflowInstallmentScheduleIntent.count).to eq(0)
      expect(ScheduleWorkflowInstallmentJob.jobs).to be_empty
    end

    it "commits publication with a pending intent if the fast-path push returns no job id" do
      workflow = create(:workflow)
      installment = create(:workflow_installment, workflow:, seller: workflow.seller)
      allow_any_instance_of(User).to receive(:eligible_to_send_emails?).and_return(true)
      allow(ScheduleWorkflowInstallmentJob).to receive(:perform_async).and_return(nil)

      workflow.publish!

      expect(workflow.reload.published_at).to be_present
      expect(installment.reload.published_at).to eq(workflow.published_at)
      expect(WorkflowInstallmentScheduleIntent.pending.sole.installment_id).to eq(installment.id)
    end

    it "commits every intent if a later fast-path push raises" do
      workflow = create(:workflow)
      installments = create_list(:workflow_installment, 2, workflow:, seller: workflow.seller)
      allow_any_instance_of(User).to receive(:eligible_to_send_emails?).and_return(true)
      tokens = []
      allow(ScheduleWorkflowInstallmentJob).to receive(:perform_async).and_wrap_original do |method, token|
        tokens << token
        raise "Redis is unavailable" if tokens.size == 2

        method.call(token)
      end

      workflow.publish!

      expect(workflow.reload.published_at).to be_present
      expect(installments.map { _1.reload.published_at }).to all(eq(workflow.published_at))
      expect(WorkflowInstallmentScheduleIntent.pending.pluck(:token)).to match_array(tokens)
      expect(ScheduleWorkflowInstallmentJob.jobs.sole.fetch("args")).to eq([tokens.first])
    end

    it "locks the workflow before unpublishing installments" do
      workflow = create(:workflow, published_at: 1.day.ago)
      installment = create(:workflow_installment, workflow:, seller: workflow.seller, published_at: workflow.published_at)
      previous_rule_version = installment.installment_rule.version
      expect(workflow).to receive(:lock!).and_call_original
      expect_any_instance_of(Installment).to receive(:unpublish!).and_wrap_original do |method|
        expect(InstallmentRule.cached_version(installment.id)).to eq(previous_rule_version + 1)
        method.call
      end

      workflow.unpublish!

      expect(installment.reload).not_to be_published
      expect(installment.installment_rule.reload.version).to eq(previous_rule_version + 1)
    end
  end

  describe "#schedule_installment", :freeze_time do
    it "carries the cutoff, rule version, and schedule intent into the recipient fanout" do
      workflow = create(:audience_workflow, published_at: 1.day.ago)
      installment = create(
        :workflow_installment,
        workflow:,
        seller: workflow.seller,
        published_at: workflow.published_at,
        is_for_new_customers_of_workflow: false,
      )
      cutoff_reference_time = Time.current.change(usec: 0)
      minimum_rule_version = installment.installment_rule.version
      schedule_intent_token = SecureRandom.uuid

      result = workflow.schedule_installment(
        installment,
        old_delayed_delivery_time: 6.hours.to_i,
        cutoff_reference_time:,
        minimum_rule_version:,
        schedule_intent_token:
      )

      expect(result).to eq(:enqueued)
      expect(SendWorkflowPostEmailsJob).to have_enqueued_sidekiq_job(
        installment.id,
        (cutoff_reference_time - 6.hours).iso8601,
        false,
        minimum_rule_version,
        schedule_intent_token
      )
    end

    it "carries the rule version and schedule intent into the cancellation fanout" do
      workflow = create(
        :workflow,
        workflow_trigger: Workflow::MEMBER_CANCELLATION_WORKFLOW_TRIGGER,
        send_to_past_customers: true,
        published_at: 1.day.ago,
      )
      installment = create(:workflow_installment, workflow:, seller: workflow.seller, published_at: workflow.published_at)
      minimum_rule_version = installment.installment_rule.version
      schedule_intent_token = SecureRandom.uuid

      result = workflow.schedule_installment(installment, minimum_rule_version:, schedule_intent_token:)

      expect(result).to eq(:enqueued)
      expect(SendWorkflowEmailsToPastCanceledMembersJob).to have_enqueued_sidekiq_job(
        installment.id,
        nil,
        nil,
        minimum_rule_version,
        schedule_intent_token
      )
    end
  end
end
