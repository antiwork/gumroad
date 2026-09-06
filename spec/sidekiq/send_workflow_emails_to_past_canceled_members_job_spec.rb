# frozen_string_literal: true

require "spec_helper"

describe SendWorkflowEmailsToPastCanceledMembersJob, :freeze_time do
  before do
    @seller = create(:user)
    @product = create(:subscription_product, user: @seller)
    @workflow = create(:workflow, seller: @seller, link: @product, workflow_trigger: Workflow::MEMBER_CANCELLATION_WORKFLOW_TRIGGER, send_to_past_customers: true)
    @installment = create(:published_installment, link: @product, workflow: @workflow, workflow_trigger: Workflow::MEMBER_CANCELLATION_WORKFLOW_TRIGGER)
    @rule = create(:installment_rule, installment: @installment, delayed_delivery_time: 14.days)

    unless RSpec.current_example.metadata[:rule_version_only]
      @canceled_subscription = create(:subscription, link: @product, cancelled_at: 30.days.ago, deactivated_at: 30.days.ago)
      create(:purchase, is_original_subscription_purchase: true, link: @product, subscription: @canceled_subscription, created_at: 60.days.ago)
    end
  end

  it "schedules a worker immediately for past cancellations whose deactivated_at + delay is in the past" do
    described_class.new.perform(@installment.id)

    expect(SendWorkflowInstallmentWorker.jobs.size).to eq(1)
    expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@installment.id, @rule.version, nil, nil, nil, @canceled_subscription.id).immediately
  end

  it "schedules a worker at deactivated_at + delay when that time is in the future" do
    recent = create(:subscription, link: @product, cancelled_at: 1.hour.ago, deactivated_at: 1.hour.ago)
    create(:purchase, is_original_subscription_purchase: true, link: @product, subscription: recent, created_at: 2.hours.ago)

    described_class.new.perform(@installment.id)

    expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@installment.id, @rule.version, nil, nil, nil, recent.id).at(recent.deactivated_at + @rule.delayed_delivery_time)
  end

  it "retries if the required rule version is not visible", :rule_version_only do
    expect(ApplicationRecord).to receive(:connected_to).with(role: :writing).at_least(:once).and_call_original

    expect do
      described_class.new.perform(@installment.id, nil, nil, @rule.version + 1)
    end.to raise_error(described_class::RuleNotCommittedError)
  end

  [false, true].each do |rescheduling|
    it "pins rule reads and #{rescheduling ? "pins rescheduled" : "releases ordinary"} cancellation scans", :rule_version_only do
      writing = false
      phases = []
      allow(ApplicationRecord).to receive(:connected_to).and_wrap_original do |original, **options, &block|
        previous = writing
        writing = options[:role] == :writing
        original.call(**options, &block)
      ensure
        writing = previous
      end
      job = described_class.new
      allow(Installment).to receive(:find_by).and_wrap_original do |original, **options|
        phases << [:post, writing]
        original.call(**options)
      end
      allow(job).to receive(:cache_rule_version).and_wrap_original do |original, rule|
        phases << [:rule, writing]
        original.call(rule)
      end
      allow(job).to receive(:candidate_subscriptions).and_wrap_original do |original, *args, **options|
        phases << [:subscriptions, writing]
        original.call(*args, **options)
      end

      job.perform(@installment.id, rescheduling ? 2.days.to_i : nil, rescheduling ? Time.current.iso8601 : nil, @rule.version)

      expect(phases).to eq([[:post, true], [:rule, true], [:subscriptions, rescheduling]])
    end
  end

  it "continues when the version cache is unavailable", :rule_version_only do
    subscription = create(:subscription, link: @product, cancelled_at: 30.days.ago, deactivated_at: 30.days.ago)
    create(:free_purchase, is_original_subscription_purchase: true, link: @product, subscription:, created_at: 60.days.ago)
    error = RedisClient::Error.new("cache unavailable")
    allow_any_instance_of(InstallmentRule).to receive(:cache_version!).and_raise(error)
    expect(ErrorNotifier).to receive(:notify).with(error, installment_rule_id: @rule.id)

    described_class.new.perform(@installment.id)

    expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@installment.id, @rule.version, nil, nil, nil, subscription.id)
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

  it "does not reschedule a cancellation before publication" do
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
    create(:purchase, is_original_subscription_purchase: true, link: @product, subscription: pending)
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
      create(:purchase, is_original_subscription_purchase: true, link: @other_product, subscription: @other_product_canceled_subscription, created_at: 60.days.ago)

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

describe SendWorkflowEmailsToPastCanceledMembersJob, "primary repair scans", :freeze_time do
  it "does not treat a missing old delay as a cancellation repair" do
    seller = create(:user)
    product = create(:subscription_product, user: seller)
    workflow = create(
      :workflow,
      seller:,
      link: product,
      workflow_trigger: Workflow::MEMBER_CANCELLATION_WORKFLOW_TRIGGER,
      send_to_past_customers: false
    )
    installment = create(
      :published_installment,
      link: product,
      workflow:,
      workflow_trigger: Workflow::MEMBER_CANCELLATION_WORKFLOW_TRIGGER
    )
    rule = create(:installment_rule, installment:, delayed_delivery_time: 14.days)

    described_class.new.perform(installment.id, nil, Time.current.iso8601, rule.version)

    expect(SendWorkflowInstallmentRescheduleJob.jobs).to be_empty
    expect(SendWorkflowInstallmentWorker.jobs).to be_empty
  end

  it "limits cancellation repairs to deactivations strictly inside the prior delay window" do
    seller = create(:user)
    product = create(:subscription_product, user: seller)
    workflow = create(
      :workflow,
      seller:,
      link: product,
      workflow_trigger: Workflow::MEMBER_CANCELLATION_WORKFLOW_TRIGGER
    )
    cutoff_reference_time = Time.current.change(usec: 0)
    old_delayed_delivery_time = 2.days
    boundary = create(
      :subscription,
      link: product,
      cancelled_at: cutoff_reference_time - old_delayed_delivery_time,
      deactivated_at: cutoff_reference_time - old_delayed_delivery_time
    )
    inside = create(
      :subscription,
      link: product,
      cancelled_at: cutoff_reference_time - old_delayed_delivery_time + 1.second,
      deactivated_at: cutoff_reference_time - old_delayed_delivery_time + 1.second
    )
    historical = create(
      :subscription,
      link: product,
      cancelled_at: cutoff_reference_time - old_delayed_delivery_time - 1.day,
      deactivated_at: cutoff_reference_time - old_delayed_delivery_time - 1.day
    )

    candidates = described_class.new.send(
      :candidate_subscriptions,
      workflow,
      deactivated_after: cutoff_reference_time - old_delayed_delivery_time
    )

    expect(candidates).to include(inside)
    expect(candidates).not_to include(boundary, historical)
  end

  it "keeps a repair scan on the primary connection" do
    seller = create(:user)
    product = create(:subscription_product, user: seller)
    workflow = create(
      :workflow,
      seller:,
      link: product,
      workflow_trigger: Workflow::MEMBER_CANCELLATION_WORKFLOW_TRIGGER,
      send_to_past_customers: false
    )
    installment = create(
      :published_installment,
      link: product,
      workflow:,
      workflow_trigger: Workflow::MEMBER_CANCELLATION_WORKFLOW_TRIGGER
    )
    rule = create(:installment_rule, installment:, delayed_delivery_time: 14.days)
    job = described_class.new
    cutoff_reference_time = Time.current.change(usec: 0)
    candidate_scope = instance_double(ActiveRecord::Relation)
    loaded_scope = instance_double(ActiveRecord::Relation)
    expect(ApplicationRecord).to receive(:connected_to).with(role: :writing).twice.ordered.and_call_original
    expect(job).to receive(:candidate_subscriptions).with(
      workflow,
      deactivated_after: cutoff_reference_time - 2.days
    ).ordered.and_return(candidate_scope)
    expect(candidate_scope).to receive(:includes).with(:original_purchase).ordered.and_return(loaded_scope)
    expect(loaded_scope).to receive(:find_each).ordered

    job.perform(
      installment.id,
      2.days.to_i,
      cutoff_reference_time.iso8601,
      rule.version
    )
  end
end
