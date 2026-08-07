# frozen_string_literal: true

require "spec_helper"

describe SendWorkflowEmailsToPastCanceledMembersJob, :freeze_time do
  before do
    @seller = create(:user)
    @product = create(:subscription_product, user: @seller)
    @workflow = create(:workflow, seller: @seller, link: @product, workflow_trigger: Workflow::MEMBER_CANCELLATION_WORKFLOW_TRIGGER, send_to_past_customers: true)
    @installment = create(:published_installment, link: @product, workflow: @workflow, workflow_trigger: Workflow::MEMBER_CANCELLATION_WORKFLOW_TRIGGER)
    @rule = create(:installment_rule, installment: @installment, delayed_delivery_time: 14.days)

    @canceled_subscription = create(:subscription, link: @product, cancelled_at: 30.days.ago, deactivated_at: 30.days.ago)
    create(:free_purchase, is_original_subscription_purchase: true, link: @product, subscription: @canceled_subscription, created_at: 60.days.ago)
  end

  it "schedules a worker immediately for past cancellations whose deactivated_at + delay is in the past" do
    described_class.new.perform(@installment.id)

    expect(SendWorkflowInstallmentWorker.jobs.size).to eq(1)
    expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@installment.id, @rule.version, nil, nil, nil, @canceled_subscription.id).immediately
  end

  it "schedules a worker at deactivated_at + delay when that time is in the future" do
    recent = create(:subscription, link: @product, cancelled_at: 1.hour.ago, deactivated_at: 1.hour.ago)
    create(:free_purchase, is_original_subscription_purchase: true, link: @product, subscription: recent, created_at: 2.hours.ago)

    described_class.new.perform(@installment.id)

    expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@installment.id, @rule.version, nil, nil, nil, recent.id).at(recent.deactivated_at + @rule.delayed_delivery_time)
  end

  it "does nothing when the workflow has been deleted" do
    @workflow.mark_deleted!
    described_class.new.perform(@installment.id)
    expect(SendWorkflowInstallmentWorker.jobs).to be_empty
  end

  it "does nothing when the installment has been deleted" do
    @installment.mark_deleted!
    described_class.new.perform(@installment.id)
    expect(SendWorkflowInstallmentWorker.jobs).to be_empty
  end

  it "does nothing when the installment is unpublished" do
    @installment.update!(published_at: nil)
    described_class.new.perform(@installment.id)
    expect(SendWorkflowInstallmentWorker.jobs).to be_empty
  end

  it "does nothing when send_to_past_customers is false" do
    @workflow.update!(send_to_past_customers: false)
    described_class.new.perform(@installment.id)
    expect(SendWorkflowInstallmentWorker.jobs).to be_empty
  end

  it "reschedules pending cancellation emails when send_to_past_customers is false" do
    @workflow.update!(send_to_past_customers: false)
    @installment.update!(published_at: 2.hours.ago, is_for_new_customers_of_workflow: true)
    recent = create(:subscription, link: @product, cancelled_at: 1.hour.ago, deactivated_at: 1.hour.ago)
    create(:free_purchase, is_original_subscription_purchase: true, link: @product, subscription: recent, created_at: 2.hours.ago)
    old_delayed_delivery_time = 2.days.to_i

    described_class.new.perform(
      @installment.id,
      old_delayed_delivery_time,
      Time.current.iso8601
    )

    reference_time = recent.deactivated_at.change(usec: 0)
    expect(SendWorkflowInstallmentRescheduleJob).to have_enqueued_sidekiq_job(
      @installment.id,
      @rule.version,
      nil,
      nil,
      nil,
      recent.id,
      reference_time.iso8601
    ).at(reference_time + @rule.delayed_delivery_time)
    expect(SendWorkflowInstallmentRescheduleJob.jobs.size).to eq(1)
    expect(SendWorkflowInstallmentWorker.jobs).to be_empty
  end

  it "does not reschedule a cancellation that predates publication for a new-recipient workflow" do
    @workflow.update!(send_to_past_customers: false)
    @installment.update!(published_at: 2.hours.ago, is_for_new_customers_of_workflow: true)
    old = create(:subscription, link: @product, cancelled_at: 3.hours.ago, deactivated_at: 3.hours.ago)
    create(:free_purchase, is_original_subscription_purchase: true, link: @product, subscription: old, created_at: 1.day.ago)

    described_class.new.perform(
      @installment.id,
      2.days.to_i,
      Time.current.iso8601
    )

    expect(SendWorkflowInstallmentRescheduleJob.jobs).to be_empty
    expect(SendWorkflowInstallmentWorker.jobs).to be_empty
  end

  it "does nothing when workflow trigger is not member_cancellation" do
    @workflow.update!(workflow_trigger: nil)
    described_class.new.perform(@installment.id)
    expect(SendWorkflowInstallmentWorker.jobs).to be_empty
  end

  it "does nothing when workflow type is not seller, product, or variant" do
    audience_workflow = create(:audience_workflow, seller: @seller, workflow_trigger: Workflow::MEMBER_CANCELLATION_WORKFLOW_TRIGGER, send_to_past_customers: true)
    audience_installment = create(:published_installment, workflow: audience_workflow, workflow_trigger: Workflow::MEMBER_CANCELLATION_WORKFLOW_TRIGGER)
    create(:installment_rule, installment: audience_installment, delayed_delivery_time: 14.days)

    described_class.new.perform(audience_installment.id)
    expect(SendWorkflowInstallmentWorker.jobs).to be_empty
  end

  it "does nothing when the installment has no rule" do
    @rule.destroy!
    described_class.new.perform(@installment.id)
    expect(SendWorkflowInstallmentWorker.jobs).to be_empty
  end

  it "skips alive subscriptions" do
    create(:subscription, link: @product)
    described_class.new.perform(@installment.id)
    expect(SendWorkflowInstallmentWorker.jobs.size).to eq(1)
    expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@installment.id, @rule.version, nil, nil, nil, @canceled_subscription.id)
  end

  it "skips pending-cancellation subscriptions (not yet deactivated)" do
    pending = create(:subscription, link: @product, cancelled_at: 1.hour.from_now)
    create(:free_purchase, is_original_subscription_purchase: true, link: @product, subscription: pending)
    described_class.new.perform(@installment.id)
    expect(SendWorkflowInstallmentWorker.jobs.size).to eq(1)
    expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@installment.id, @rule.version, nil, nil, nil, @canceled_subscription.id)
  end

  context "for a seller-type workflow" do
    before do
      @other_seller_product = create(:subscription_product)
      create(:subscription, link: @other_seller_product, cancelled_at: 30.days.ago, deactivated_at: 30.days.ago)

      @other_product = create(:subscription_product, user: @seller)
      @other_product_canceled_subscription = create(:subscription, link: @other_product, cancelled_at: 30.days.ago, deactivated_at: 30.days.ago)
      create(:free_purchase, is_original_subscription_purchase: true, link: @other_product, subscription: @other_product_canceled_subscription, created_at: 60.days.ago)

      @seller_workflow = create(:seller_workflow, seller: @seller, workflow_trigger: Workflow::MEMBER_CANCELLATION_WORKFLOW_TRIGGER, send_to_past_customers: true)
      @seller_installment = create(:published_installment, workflow: @seller_workflow, workflow_trigger: Workflow::MEMBER_CANCELLATION_WORKFLOW_TRIGGER)
      @seller_rule = create(:installment_rule, installment: @seller_installment, delayed_delivery_time: 14.days)
    end

    it "schedules workers for canceled subscriptions across all seller's products" do
      described_class.new.perform(@seller_installment.id)

      expect(SendWorkflowInstallmentWorker.jobs.size).to eq(2)
      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@seller_installment.id, @seller_rule.version, nil, nil, nil, @canceled_subscription.id)
      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@seller_installment.id, @seller_rule.version, nil, nil, nil, @other_product_canceled_subscription.id)
    end
  end
end
