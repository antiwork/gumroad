# frozen_string_literal: true

describe ScheduleWorkflowInstallmentJob do
  let(:workflow) { create(:audience_workflow, published_at: 1.day.ago) }
  let(:installment) { create(:workflow_installment, workflow:, seller: workflow.seller, published_at: workflow.published_at) }
  let(:rule) { installment.installment_rule }
  let(:cutoff_reference_time) { Time.current.change(usec: 0) }

  it "schedules the installment after the expected rule version commits" do
    expect_any_instance_of(Workflow).to receive(:schedule_installment)
      .with(
        kind_of(Installment),
        old_delayed_delivery_time: 1.hour.to_i,
        cutoff_reference_time:,
        reschedule_on_stale: true
      )

    described_class.new.perform(installment.id, rule.version, 1.hour.to_i, cutoff_reference_time.iso8601)
  end

  it "retries while the expected rule version is not visible" do
    expect do
      described_class.new.perform(installment.id, rule.version + 1, 1.hour.to_i, cutoff_reference_time.iso8601)
    end.to raise_error(ScheduleWorkflowInstallmentJob::RuleNotCommittedError)
  end

  it "preserves the recipient window from a superseded rule version" do
    expect_any_instance_of(Workflow).to receive(:schedule_installment)
      .with(
        kind_of(Installment),
        old_delayed_delivery_time: 1.hour.to_i,
        cutoff_reference_time:,
        reschedule_on_stale: true
      )

    described_class.new.perform(installment.id, rule.version - 1, 1.hour.to_i, cutoff_reference_time.iso8601)
  end

  it "retries while a new installment is not visible" do
    expect do
      described_class.new.perform(-1, 1, nil, cutoff_reference_time.iso8601)
    end.to raise_error(ScheduleWorkflowInstallmentJob::RuleNotCommittedError)
  end

  it "reschedules a pending email for a resubscribed membership outside the normal purchase cutoff" do
    product = create(:subscription_product)
    subscription = create(:subscription, link: product)
    purchase = create(
      :free_purchase,
      link: product,
      subscription:,
      is_original_subscription_purchase: true,
      created_at: 10.days.ago
    )
    create(:subscription_event, subscription:, event_type: :deactivated, occurred_at: 9.days.ago)
    create(:subscription_event, subscription:, event_type: :restarted, occurred_at: 1.day.ago)
    workflow = create(:workflow, seller: product.user, link: product, published_at: 1.day.ago)
    installment = create(:workflow_installment, workflow:, seller: product.user, link: product, published_at: workflow.published_at)
    rule = installment.installment_rule
    rule.update!(delayed_delivery_time: 7.days)
    old_delayed_delivery_time = 3.days.to_i
    reference_time = installment.workflow_delivery_reference_time(purchase).change(usec: 0)

    described_class.new.perform(
      installment.id,
      rule.version,
      old_delayed_delivery_time,
      cutoff_reference_time.iso8601
    )

    expect(purchase.created_at + old_delayed_delivery_time).to be < cutoff_reference_time
    expect(reference_time + old_delayed_delivery_time).to be > cutoff_reference_time
    expect(SendWorkflowInstallmentRescheduleJob).to have_enqueued_sidekiq_job(
      installment.id,
      rule.version,
      purchase.id,
      nil,
      nil,
      nil,
      reference_time.iso8601
    ).at(reference_time + rule.delayed_delivery_time)
  end
end
