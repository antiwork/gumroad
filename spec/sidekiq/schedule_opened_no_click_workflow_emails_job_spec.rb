# frozen_string_literal: true

require "spec_helper"

describe ScheduleOpenedNoClickWorkflowEmailsJob do
  it "queues a scan for each published email of an opened-no-click workflow, and nothing else" do
    seller = create(:user)
    product = create(:product, user: seller)
    watched_post = create(:published_installment, seller:, link: product)
    ours = create(:workflow, seller:, link: product, workflow_trigger: Workflow::OPENED_NO_CLICK_WORKFLOW_TRIGGER,
                             workflow_trigger_post_id: watched_post.external_id)
    our_email = create(:published_installment, link: product, workflow: ours, workflow_trigger: Workflow::OPENED_NO_CLICK_WORKFLOW_TRIGGER)
    create(:installment, link: product, workflow: ours, workflow_trigger: Workflow::OPENED_NO_CLICK_WORKFLOW_TRIGGER)
    other = create(:workflow, seller:, link: product)
    create(:published_installment, link: product, workflow: other)
    deleted = create(:workflow, seller:, link: product, workflow_trigger: Workflow::OPENED_NO_CLICK_WORKFLOW_TRIGGER,
                                workflow_trigger_post_id: watched_post.external_id)
    create(:published_installment, link: product, workflow: deleted, workflow_trigger: Workflow::OPENED_NO_CLICK_WORKFLOW_TRIGGER)
    deleted.mark_deleted!

    described_class.new.perform

    expect(SendWorkflowEmailsToOpenedNonClickersJob).to have_enqueued_sidekiq_job(our_email.id)
    expect(SendWorkflowEmailsToOpenedNonClickersJob.jobs.size).to eq(1)
  end
end
