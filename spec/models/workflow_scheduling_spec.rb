# frozen_string_literal: true

describe Workflow do
  describe "#mark_deleted!" do
    it "locks the workflow before deleting its installments" do
      workflow = create(:workflow)
      installment = create(:workflow_installment, workflow:, seller: workflow.seller)
      expect(workflow).to receive(:lock!).and_call_original

      workflow.mark_deleted!

      expect(workflow).to be_deleted
      expect(installment.reload).to be_deleted
      expect(installment.installment_rule.reload).to be_deleted
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

    it "defers recipient scheduling until publication commits" do
      workflow = create(:workflow)
      installment = create(:workflow_installment, workflow:, seller: workflow.seller)
      allow_any_instance_of(User).to receive(:eligible_to_send_emails?).and_return(true)
      expect(AfterCommitEverywhere).to receive(:after_commit).and_yield
      expect(workflow).to receive(:schedule_installment).with(installment)

      workflow.publish!
    end

    it "locks the workflow before unpublishing installments" do
      workflow = create(:workflow, published_at: 1.day.ago)
      installment = create(:workflow_installment, workflow:, seller: workflow.seller, published_at: workflow.published_at)
      expect(workflow).to receive(:lock!).and_call_original

      workflow.unpublish!

      expect(installment.reload).not_to be_published
    end
  end

  describe "#schedule_installment", :freeze_time do
    it "uses the supplied cutoff reference time" do
      workflow = create(:audience_workflow, published_at: 1.day.ago)
      installment = create(
        :workflow_installment,
        workflow:,
        seller: workflow.seller,
        published_at: workflow.published_at,
        is_for_new_customers_of_workflow: false,
      )
      old_delayed_delivery_time = 6.hours.to_i
      cutoff_reference_time = 2.days.ago

      workflow.schedule_installment(installment, old_delayed_delivery_time:, cutoff_reference_time:)

      expect(SendWorkflowPostEmailsJob).to have_enqueued_sidekiq_job(
        installment.id,
        (cutoff_reference_time - old_delayed_delivery_time.seconds).iso8601
      )
    end

    it "carries the observed rule version into a reschedule scan" do
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

      workflow.schedule_installment(
        installment,
        old_delayed_delivery_time: 6.hours.to_i,
        cutoff_reference_time:,
        reschedule_on_stale: true,
        minimum_rule_version:
      )

      expect(SendWorkflowPostEmailsJob).to have_enqueued_sidekiq_job(
        installment.id,
        (cutoff_reference_time - 6.hours).iso8601,
        true,
        minimum_rule_version
      )
    end

    it "repairs recipients added during a new installment transaction" do
      workflow = create(:audience_workflow, published_at: 1.day.ago, send_to_past_customers: false)
      installment = create(
        :workflow_installment,
        workflow:,
        seller: workflow.seller,
        published_at: Time.current,
        is_for_new_customers_of_workflow: true,
      )
      minimum_rule_version = installment.installment_rule.version

      workflow.schedule_installment(
        installment,
        old_delayed_delivery_time: nil,
        reschedule_on_stale: true,
        minimum_rule_version:
      )

      expect(SendWorkflowPostEmailsJob).to have_enqueued_sidekiq_job(
        installment.id,
        installment.published_at.iso8601,
        true,
        minimum_rule_version
      )
    end

    it "reschedules pending cancellation emails after a rule edit for a new-recipient workflow" do
      workflow = create(
        :workflow,
        workflow_trigger: Workflow::MEMBER_CANCELLATION_WORKFLOW_TRIGGER,
        send_to_past_customers: false
      )
      installment = create(:published_installment, workflow:, seller: workflow.seller, link: workflow.link)
      rule = create(:installment_rule, installment:)
      cutoff_reference_time = Time.current.change(usec: 0)
      minimum_rule_version = rule.version

      workflow.schedule_installment(
        installment,
        old_delayed_delivery_time: 1.day.to_i,
        cutoff_reference_time:,
        reschedule_on_stale: true,
        minimum_rule_version:
      )

      expect(SendWorkflowEmailsToPastCanceledMembersJob).to have_enqueued_sidekiq_job(
        installment.id,
        1.day.to_i,
        cutoff_reference_time.iso8601,
        minimum_rule_version
      )
      expect(SendWorkflowPostEmailsJob.jobs).to be_empty
    end
  end
end
