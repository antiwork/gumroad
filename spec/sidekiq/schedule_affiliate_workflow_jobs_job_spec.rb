# frozen_string_literal: true

describe ScheduleAffiliateWorkflowJobsJob do
  let(:affiliate) { create(:direct_affiliate, send_posts: true) }
  let(:product) { create(:product, user: affiliate.seller) }
  let(:product_affiliate) { create(:product_affiliate, affiliate:, product:) }
  let(:workflow_schedule_token) { product_affiliate.reload.workflow_schedule_token }

  it "schedules workflows after the product assignment commits" do
    product_affiliate
    expect(ApplicationRecord).to receive(:connected_to).with(role: :writing).at_least(:once).and_call_original
    expect_any_instance_of(DirectAffiliate).to receive(:schedule_workflow_jobs).with(
      triggering_product_affiliates: [product_affiliate]
    )

    described_class.new.perform(workflow_schedule_token)

    expect(product_affiliate.reload.workflow_schedule_token).to be_nil
  end

  it "ignores an assignment group that no longer exists" do
    expect do
      described_class.new.perform(SecureRandom.uuid)
    end.not_to raise_error
  end

  it "dispatches pending assignment groups" do
    pending_token = SecureRandom.uuid
    product_affiliate.update_columns(workflow_schedule_token: pending_token)
    ScheduleAffiliateWorkflowJobsJob.jobs.clear

    described_class.new.perform

    claimed_token = product_affiliate.reload.workflow_schedule_token
    expect(claimed_token).not_to eq(pending_token)
    expect(described_class).to have_enqueued_sidekiq_job(claimed_token)
  end

  it "does not redispatch a live claim" do
    workflow_schedule_token
    ScheduleAffiliateWorkflowJobsJob.jobs.clear

    described_class.new.perform

    expect(described_class.jobs).to be_empty
  end

  it "redispatches an expired claim" do
    original_claim = workflow_schedule_token
    ScheduleAffiliateWorkflowJobsJob.jobs.clear

    travel ProductAffiliate::WORKFLOW_SCHEDULE_DISPATCH_LEASE + 1.minute do
      described_class.new.perform
    end

    claimed_token = product_affiliate.reload.workflow_schedule_token
    expect(claimed_token).not_to eq(original_claim)
    expect(described_class).to have_enqueued_sidekiq_job(claimed_token)
  end

  it "schedules all affiliates in the assignment group" do
    second_affiliate = create(:direct_affiliate, seller: affiliate.seller, send_posts: true)
    second_product = create(:product, user: affiliate.seller)
    assignments = []
    ProductAffiliate.transaction do
      assignments << product_affiliate
      assignments << create(:product_affiliate, affiliate: second_affiliate, product: second_product)
    end
    scheduled_affiliate_ids = []
    allow_any_instance_of(DirectAffiliate).to receive(:schedule_workflow_jobs) do |scheduled_affiliate|
      scheduled_affiliate_ids << scheduled_affiliate.id
    end

    described_class.new.perform(assignments.first.reload.workflow_schedule_token)

    expect(scheduled_affiliate_ids).to match_array([affiliate.id, second_affiliate.id])
  end

  it "does not schedule after the affiliate is deleted" do
    product_affiliate
    affiliate.mark_deleted!
    expect_any_instance_of(DirectAffiliate).not_to receive(:schedule_workflow_jobs)

    described_class.new.perform(workflow_schedule_token)

    expect(product_affiliate.reload.workflow_schedule_token).to be_nil
  end

  it "does not schedule after the affiliate opts out" do
    product_affiliate
    affiliate.update_posts_subscription(send_posts: false)
    expect_any_instance_of(DirectAffiliate).not_to receive(:schedule_workflow_jobs)

    described_class.new.perform(workflow_schedule_token)

    expect(product_affiliate.reload.workflow_schedule_token).to be_nil
  end

  it "retries only the affiliates that did not complete" do
    second_affiliate = create(:direct_affiliate, seller: affiliate.seller, send_posts: true)
    second_product = create(:product, user: affiliate.seller)
    assignments = []
    ProductAffiliate.transaction do
      assignments << product_affiliate
      assignments << create(:product_affiliate, affiliate: second_affiliate, product: second_product)
    end
    token = assignments.first.reload.workflow_schedule_token

    calls = Hash.new(0)
    failed_affiliate_id = nil
    allow_any_instance_of(DirectAffiliate).to receive(:schedule_workflow_jobs) do |scheduled_affiliate|
      calls[scheduled_affiliate.id] += 1
      if failed_affiliate_id.nil? && calls.size == 2
        failed_affiliate_id = scheduled_affiliate.id
        raise ProductAffiliate::WorkflowJobNotEnqueuedError
      end
    end

    expect do
      described_class.new.perform(token)
    end.to raise_error(ProductAffiliate::WorkflowJobNotEnqueuedError)

    completed_affiliate_id = calls.keys.find { _1 != failed_affiliate_id }
    completed_assignment = assignments.find { _1.affiliate_id == completed_affiliate_id }
    failed_assignment = assignments.find { _1.affiliate_id == failed_affiliate_id }
    expect(completed_assignment.reload.workflow_schedule_token).to be_nil
    expect(failed_assignment.reload.workflow_schedule_token).to eq(token)

    described_class.new.perform(token)

    expect(calls[completed_affiliate_id]).to eq(1)
    expect(calls[failed_affiliate_id]).to eq(2)
    expect(failed_assignment.reload.workflow_schedule_token).to be_nil
  end

  it "does not clear a claim that replaced an expired lease" do
    product_affiliate
    replacement_token = "#{Time.current.to_i}:#{SecureRandom.uuid}"
    allow_any_instance_of(DirectAffiliate).to receive(:schedule_workflow_jobs) do
      ProductAffiliate.where(id: product_affiliate.id).update_all(workflow_schedule_token: replacement_token)
    end

    described_class.new.perform(workflow_schedule_token)

    expect(product_affiliate.reload.workflow_schedule_token).to eq(replacement_token)
  end

  it "keeps the assignment group pending when delivery scheduling fails" do
    product_affiliate
    allow_any_instance_of(DirectAffiliate).to receive(:schedule_workflow_jobs).and_raise(ProductAffiliate::WorkflowJobNotEnqueuedError)

    expect do
      described_class.new.perform(workflow_schedule_token)
    end.to raise_error(ProductAffiliate::WorkflowJobNotEnqueuedError)

    expect(product_affiliate.reload.workflow_schedule_token).to be_present
  end
end
