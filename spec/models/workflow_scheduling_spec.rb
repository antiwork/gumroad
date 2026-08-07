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

    it "reschedules pending cancellation emails after a rule edit for a new-recipient workflow" do
      workflow = create(
        :workflow,
        workflow_trigger: Workflow::MEMBER_CANCELLATION_WORKFLOW_TRIGGER,
        send_to_past_customers: false
      )
      installment = create(:published_installment, workflow:, seller: workflow.seller, link: workflow.link)
      cutoff_reference_time = Time.current.change(usec: 0)

      workflow.schedule_installment(
        installment,
        old_delayed_delivery_time: 1.day.to_i,
        cutoff_reference_time:,
        reschedule_on_stale: true
      )

      expect(SendWorkflowEmailsToPastCanceledMembersJob).to have_enqueued_sidekiq_job(
        installment.id,
        1.day.to_i,
        cutoff_reference_time.iso8601
      )
      expect(SendWorkflowPostEmailsJob.jobs).to be_empty
    end
  end
end
