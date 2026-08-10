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

    workflow.publish!

    expect(installment.reload).to be_published
    expect(rule.reload.version).to eq(previous_version + 1)
    expect(SendWorkflowPostEmailsJob).to have_enqueued_sidekiq_job(installment.id, nil)
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
