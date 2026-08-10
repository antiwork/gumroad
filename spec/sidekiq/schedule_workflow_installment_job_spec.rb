# frozen_string_literal: true

require "spec_helper"

describe ScheduleWorkflowInstallmentJob do
  let(:workflow) { create(:audience_workflow, published_at: 1.day.ago) }
  let(:installment) { create(:workflow_installment, workflow:, seller: workflow.seller, published_at: workflow.published_at) }
  let(:rule) { installment.installment_rule }
  let(:cutoff_reference_time) { Time.current.change(usec: 0) }

  def create_intent(**attributes)
    WorkflowInstallmentScheduleIntent.create!(
      {
        token: SecureRandom.uuid,
        installment_id: installment.id,
        rule_version: rule.version,
        old_delayed_delivery_time: 1.hour.to_i,
        cutoff_reference_time:,
      }.merge(attributes)
    )
  end

  it "keeps the intent pending until the recipient fanout completes" do
    intent = create_intent
    expect_any_instance_of(Workflow).to receive(:schedule_installment).with(
      kind_of(Installment),
      old_delayed_delivery_time: 1.hour.to_i,
      cutoff_reference_time:,
      minimum_rule_version: rule.version,
      schedule_intent_token: intent.token,
      schedule_intent_fanout_token: kind_of(String)
    ).and_return(:enqueued)

    described_class.new.perform(intent.token)

    expect(intent.reload.processed_at).to be_nil
    expect(intent.fanout_token).to be_present
    expect(intent.fanout_expires_at).to be > Time.current
  end

  it "ignores an intent that has already been cleaned up" do
    expect { described_class.new.perform(SecureRandom.uuid) }.not_to raise_error
  end

  it "retries while the expected rule version is not visible" do
    intent = create_intent(rule_version: rule.version + 1)

    expect do
      described_class.new.perform(intent.token)
    end.to raise_error(ScheduleWorkflowInstallmentJob::IntentNotCommittedError)

    expect(intent.reload).to be_present
  end

  it "preserves the recipient window from a superseded rule version" do
    intent = create_intent(rule_version: rule.version - 1)
    expect_any_instance_of(Workflow).to receive(:schedule_installment).with(
      kind_of(Installment),
      old_delayed_delivery_time: 1.hour.to_i,
      cutoff_reference_time:,
      minimum_rule_version: rule.version,
      schedule_intent_token: intent.token,
      schedule_intent_fanout_token: kind_of(String)
    ).and_return(:enqueued)

    described_class.new.perform(intent.token)
  end

  it "discards an intent from a rolled-back publication state" do
    expected_published_at = cutoff_reference_time
    workflow.update!(published_at: nil, first_published_at: expected_published_at)
    installment.update!(published_at: nil)
    intent = create_intent(expected_published_at:)
    expect_any_instance_of(Workflow).not_to receive(:schedule_installment)

    described_class.new.perform(intent.token)

    expect(intent.reload.processed_at).to be_present
  end

  it "schedules after workflow publication becomes visible" do
    published_at = workflow.published_at.change(usec: 0)
    installment.update!(published_at:)
    intent = create_intent(
      old_delayed_delivery_time: nil,
      cutoff_reference_time: published_at,
      expected_published_at: published_at
    )
    expect_any_instance_of(Workflow).to receive(:with_lock).and_call_original
    expect_any_instance_of(Workflow).to receive(:schedule_installment).with(
      kind_of(Installment),
      old_delayed_delivery_time: nil,
      cutoff_reference_time: published_at,
      minimum_rule_version: rule.version,
      schedule_intent_token: intent.token,
      schedule_intent_fanout_token: kind_of(String)
    ).and_return(:enqueued)

    described_class.new.perform(intent.token)
  end

  it "discards the intent after the installment becomes unpublished" do
    installment.update!(published_at: nil)
    intent = create_intent
    expect_any_instance_of(Workflow).not_to receive(:schedule_installment)

    described_class.new.perform(intent.token)

    expect(intent.reload.processed_at).to be_present
  end

  it "does not process a completed intent twice" do
    intent = create_intent
    expect_any_instance_of(Workflow).to receive(:schedule_installment).and_return(:not_applicable)

    described_class.new.perform(intent.token)
    described_class.new.perform(intent.token)

    expect(intent.reload.processed_at).to be_present
  end

  it "does not enqueue the recipient fanout twice" do
    intent = create_intent
    expect_any_instance_of(Workflow).to receive(:schedule_installment).once.and_return(:enqueued)

    described_class.new.perform(intent.token)
    described_class.new.perform(intent.token)

    expect(intent.reload.processed_at).to be_nil
    expect(intent.fanout_token).to be_present
    expect(intent.fanout_expires_at).to be > Time.current
  end

  it "keeps the intent pending if recipient scheduling fails" do
    intent = create_intent
    expect_any_instance_of(Workflow).to receive(:schedule_installment).and_raise("Redis is unavailable")

    expect { described_class.new.perform(intent.token) }.to raise_error("Redis is unavailable")

    expect(intent.reload.processed_at).to be_nil
    expect(intent.fanout_token).to be_nil
    expect(intent.fanout_expires_at).to be_nil
  end

  it "retries when client middleware cancels the recipient fanout" do
    intent = create_intent
    expect_any_instance_of(Workflow).to receive(:schedule_installment).and_return(:not_enqueued)

    expect do
      described_class.new.perform(intent.token)
    end.to raise_error(ScheduleWorkflowInstallmentJob::FanoutNotEnqueuedError)

    expect(intent.reload.processed_at).to be_nil
    expect(intent.fanout_token).to be_nil
    expect(intent.fanout_expires_at).to be_nil
  end

  it "retries an unexpected recipient scheduling result" do
    intent = create_intent
    expect_any_instance_of(Workflow).to receive(:schedule_installment).and_return(nil)

    expect do
      described_class.new.perform(intent.token)
    end.to raise_error(ScheduleWorkflowInstallmentJob::FanoutNotEnqueuedError, "Unexpected schedule result: nil")

    expect(intent.reload.processed_at).to be_nil
    expect(intent.fanout_token).to be_nil
    expect(intent.fanout_expires_at).to be_nil
  end

  it "marks the intent processed when no recipient fanout applies" do
    intent = create_intent
    expect_any_instance_of(Workflow).to receive(:schedule_installment).and_return(:not_applicable)

    described_class.new.perform(intent.token)

    expect(intent.reload.processed_at).to be_present
  end

  it "releases the primary connection after execution" do
    intent = create_intent
    expect(ActiveRecord::Base.connection).to receive(:stick_to_primary!).at_least(:once).and_call_original
    expect_any_instance_of(Workflow).to receive(:schedule_installment).and_return(:not_applicable)
    expect(Makara::Context).to receive(:release_all)

    described_class.new.perform(intent.token)
  end
end
