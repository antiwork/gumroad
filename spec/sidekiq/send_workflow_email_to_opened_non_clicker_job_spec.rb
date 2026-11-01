# frozen_string_literal: true

require "spec_helper"

describe SendWorkflowEmailToOpenedNonClickerJob, :freeze_time do
  before do
    @seller = create(:user)
    @product = create(:product, user: @seller)
    @watched_post = create(:published_installment, seller: @seller, link: @product)
    @workflow = create(:workflow, seller: @seller, link: @product, workflow_trigger: Workflow::OPENED_NO_CLICK_WORKFLOW_TRIGGER,
                                  workflow_trigger_post_id: @watched_post.external_id)
    @installment = create(:published_installment, link: @product, workflow: @workflow,
                                                  workflow_trigger: Workflow::OPENED_NO_CLICK_WORKFLOW_TRIGGER)
    @rule = create(:installment_rule, installment: @installment, delayed_delivery_time: 3.days)
    @purchase = create(:purchase, link: @product, seller: @seller)

    allow(Installment).to receive(:find_by).with(id: @installment.id).and_return(@installment)
  end

  it "sends the email the scan queued" do
    expect(@installment).to receive(:send_installment_from_workflow_for_opened_no_click).with(@purchase.id, recipient_digest: "digest-1")

    described_class.new.perform(@installment.id, @rule.version, @purchase.id, "digest-1")
  end

  it "drops a send that was queued before a delay edit" do
    expect(@installment).not_to receive(:send_installment_from_workflow_for_opened_no_click)

    described_class.new.perform(@installment.id, @rule.version - 1, @purchase.id, "digest-1")
  end

  it "does nothing once the seller is suspended" do
    allow_any_instance_of(User).to receive(:suspended?).and_return(true)
    expect(@installment).not_to receive(:send_installment_from_workflow_for_opened_no_click)

    described_class.new.perform(@installment.id, @rule.version, @purchase.id, "digest-1")
  end

  it "does nothing once the workflow is unpublished or deleted" do
    @workflow.mark_deleted!
    expect(@installment).not_to receive(:send_installment_from_workflow_for_opened_no_click)

    described_class.new.perform(@installment.id, @rule.version, @purchase.id, "digest-1")
  end

  it "does nothing for a workflow email of another trigger" do
    @installment.update!(workflow_trigger: nil)
    @workflow.update!(workflow_trigger: nil)
    expect(@installment).not_to receive(:send_installment_from_workflow_for_opened_no_click)

    described_class.new.perform(@installment.id, @rule.version, @purchase.id, "digest-1")
  end
end
