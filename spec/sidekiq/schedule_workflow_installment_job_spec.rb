# frozen_string_literal: true

require "spec_helper"

describe ScheduleWorkflowInstallmentJob do
  let(:workflow) { create(:audience_workflow, published_at: 1.day.ago) }
  let(:installment) { create(:workflow_installment, workflow:, seller: workflow.seller, published_at: workflow.published_at) }
  let(:rule) { installment.installment_rule }
  let(:cutoff_reference_time) { Time.current.change(usec: 0) }

  def create_intent(installment: nil, rule: nil, **attributes)
    installment ||= self.installment
    rule ||= installment.installment_rule
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
      reschedule_on_stale: true,
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

  it "retries a scheduler job whose dispatch token is not visible" do
    intent = create_intent
    expect_any_instance_of(Workflow).not_to receive(:schedule_installment)

    expect do
      described_class.new.perform(intent.token, SecureRandom.uuid)
    end.to raise_error(described_class::IntentNotCommittedError)

    expect(intent.reload.processed_at).to be_nil
    expect(intent.fanout_token).to be_nil
  end

  it "ignores a scheduler job whose dispatch lease was replaced" do
    intent = create_intent(dispatch_token: SecureRandom.uuid, dispatch_expires_at: 1.minute.from_now)
    expect_any_instance_of(Workflow).not_to receive(:schedule_installment)

    described_class.new.perform(intent.token, SecureRandom.uuid)

    expect(intent.reload.processed_at).to be_nil
    expect(intent.fanout_token).to be_nil
  end

  it "retries a scheduler job after the previous dispatch lease expires" do
    intent = create_intent(dispatch_token: SecureRandom.uuid, dispatch_expires_at: 1.minute.ago)
    expect_any_instance_of(Workflow).not_to receive(:schedule_installment)

    expect do
      described_class.new.perform(intent.token, SecureRandom.uuid)
    end.to raise_error(described_class::IntentNotCommittedError)

    expect(intent.reload.processed_at).to be_nil
    expect(intent.fanout_token).to be_nil
  end

  it "ignores a stale scheduler job while a fanout owns the intent" do
    intent = create_intent(
      dispatch_token: SecureRandom.uuid,
      dispatch_expires_at: 1.minute.ago,
      fanout_token: SecureRandom.uuid,
      fanout_expires_at: 1.minute.from_now
    )
    expect_any_instance_of(Workflow).not_to receive(:schedule_installment)

    expect do
      described_class.new.perform(intent.token, SecureRandom.uuid)
    end.not_to raise_error

    expect(intent.reload.processed_at).to be_nil
    expect(intent.fanout_token).to be_present
  end

  it "accepts the scheduler job whose dispatch token committed" do
    dispatch_token = SecureRandom.uuid
    intent = create_intent(dispatch_token:)
    expect(WorkflowInstallmentScheduleIntent).to receive(:lock).and_call_original
    expect_any_instance_of(Workflow).to receive(:schedule_installment).and_return(:enqueued)

    described_class.new.perform(intent.token, dispatch_token)

    expect(intent.reload.fanout_token).to be_present
  end

  it "retries while the required rule version is not visible" do
    intent = create_intent(rule_version: rule.version + 1)

    expect do
      described_class.new.perform(intent.token)
    end.to raise_error(described_class::IntentNotCommittedError)

    expect(intent.reload.processed_at).to be_nil
  end

  it "preserves the recipient window from a superseded rule version" do
    intent = create_intent(rule_version: rule.version - 1)
    expect_any_instance_of(Workflow).to receive(:schedule_installment).with(
      kind_of(Installment),
      old_delayed_delivery_time: 1.hour.to_i,
      cutoff_reference_time:,
      reschedule_on_stale: true,
      minimum_rule_version: rule.version,
      schedule_intent_token: intent.token,
      schedule_intent_fanout_token: kind_of(String)
    ).and_return(:enqueued)

    described_class.new.perform(intent.token)
  end

  it "discards an intent from a stale publication state" do
    expected_published_at = cutoff_reference_time
    workflow.update!(published_at: nil, first_published_at: expected_published_at)
    installment.update!(published_at: nil)
    intent = create_intent(expected_published_at:)
    expect_any_instance_of(Workflow).not_to receive(:schedule_installment)

    described_class.new.perform(intent.token)

    expect(intent.reload.processed_at).to be_present
  end

  it "schedules after the publication state becomes visible" do
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
      reschedule_on_stale: false,
      minimum_rule_version: rule.version,
      schedule_intent_token: intent.token,
      schedule_intent_fanout_token: kind_of(String)
    ).and_return(:enqueued)
    job = described_class.new
    expect(job).not_to receive(:reschedule_pending_resubscribed_memberships)

    job.perform(intent.token)
  end

  it "discards an intent after the installment becomes unpublished" do
    installment.update!(published_at: nil)
    intent = create_intent
    expect_any_instance_of(Workflow).not_to receive(:schedule_installment)

    described_class.new.perform(intent.token)

    expect(intent.reload.processed_at).to be_present
  end

  it "does not enqueue a recipient fanout twice" do
    intent = create_intent
    expect_any_instance_of(Workflow).to receive(:schedule_installment).once.and_return(:enqueued)

    described_class.new.perform(intent.token)
    described_class.new.perform(intent.token)

    expect(intent.reload.processed_at).to be_nil
    expect(intent.fanout_token).to be_present
    expect(intent.fanout_expires_at).to be > Time.current
  end

  it "keeps the intent pending when recipient scheduling raises" do
    intent = create_intent
    expect_any_instance_of(Workflow).to receive(:schedule_installment).and_raise("Redis is unavailable")

    expect { described_class.new.perform(intent.token) }.to raise_error("Redis is unavailable")

    expect(intent.reload.processed_at).to be_nil
    expect(intent.fanout_token).to be_nil
    expect(intent.fanout_expires_at).to be_nil
  end

  it "keeps the intent pending if resubscription scheduling fails" do
    intent = create_intent
    job = described_class.new
    expect(job).to receive(:reschedule_pending_resubscribed_memberships).and_raise("Redis is unavailable")
    expect_any_instance_of(Workflow).not_to receive(:schedule_installment)

    expect { job.perform(intent.token) }.to raise_error("Redis is unavailable")

    expect(intent.reload.processed_at).to be_nil
  end

  it "keeps the intent pending when middleware cancels the fanout" do
    intent = create_intent
    expect_any_instance_of(Workflow).to receive(:schedule_installment).and_return(:not_enqueued)

    expect do
      described_class.new.perform(intent.token)
    end.to raise_error(described_class::FanoutNotEnqueuedError, "Recipient fanout was not enqueued")

    expect(intent.reload.processed_at).to be_nil
    expect(intent.fanout_token).to be_nil
    expect(intent.fanout_expires_at).to be_nil
  end

  it "keeps the intent pending for an unexpected fanout result" do
    intent = create_intent
    expect_any_instance_of(Workflow).to receive(:schedule_installment).and_return(nil)

    expect do
      described_class.new.perform(intent.token)
    end.to raise_error(described_class::FanoutNotEnqueuedError, "Unexpected schedule result: nil")

    expect(intent.reload.processed_at).to be_nil
    expect(intent.fanout_token).to be_nil
    expect(intent.fanout_expires_at).to be_nil
  end

  it "marks the intent processed when no fanout applies" do
    intent = create_intent
    expect_any_instance_of(Workflow).to receive(:schedule_installment).and_return(:not_applicable)

    described_class.new.perform(intent.token)

    expect(intent.reload.processed_at).to be_present
  end

  it "reschedules a pending email for a resubscribed membership outside the purchase cutoff" do
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
    workflow = create(:workflow, seller: product.user, link: product, published_at: 3.days.ago)
    installment = create(
      :workflow_installment,
      workflow:,
      seller: product.user,
      link: product,
      published_at: workflow.published_at,
      is_for_new_customers_of_workflow: true
    )
    rule = installment.installment_rule
    rule.update!(delayed_delivery_time: 7.days)
    old_delayed_delivery_time = 3.days.to_i
    reference_time = installment.workflow_delivery_reference_time(purchase).change(usec: 0)
    expect_any_instance_of(Subscription).not_to receive(:last_resubscribed_at)
    expect_any_instance_of(Subscription).not_to receive(:last_deactivated_at)
    intent = create_intent(
      installment:,
      rule:,
      old_delayed_delivery_time:,
      cutoff_reference_time:
    )

    described_class.new.perform(intent.token)

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

  it "does not reschedule a restart before publication" do
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
    installment = create(
      :workflow_installment,
      workflow:,
      seller: product.user,
      link: product,
      published_at: workflow.published_at,
      is_for_new_customers_of_workflow: true
    )
    rule = installment.installment_rule
    rule.update!(delayed_delivery_time: 7.days)
    intent = create_intent(
      installment:,
      rule:,
      old_delayed_delivery_time: 3.days.to_i,
      cutoff_reference_time:
    )

    described_class.new.perform(intent.token)

    expect(installment.workflow_delivery_reference_time(purchase)).to be < installment.published_at
    expect(SendWorkflowInstallmentRescheduleJob.jobs).to be_empty
  end

  it "limits the resubscription scan to the recipient window" do
    seller = create(:user)
    product = create(:subscription_product, user: seller)
    recent_subscription = create(:subscription, link: product)
    old_subscription = create(:subscription, link: product)
    recent_restart = create(:subscription_event, subscription: recent_subscription, event_type: :restarted, occurred_at: 1.day.ago)
    recent_restart.update_columns(seller_id: nil)
    create(:subscription_event, subscription: old_subscription, event_type: :restarted, occurred_at: 10.days.ago)
    workflow = build(:seller_workflow, seller:)

    candidates = described_class.new.send(
      :candidate_subscriptions,
      workflow,
      restarted_after: 3.days.ago
    )

    expect(candidates).to include(recent_subscription)
    expect(candidates).not_to include(old_subscription)
    expect(candidates.to_sql).to include("`subscription_events`.`seller_id` = #{seller.id}")
    expect(candidates.to_sql).to include("`subscription_events`.`seller_id` IS NULL")
  end

  it "batches exclusion filters across resubscribed memberships" do
    seller = create(:user)
    product = create(:subscription_product, user: seller)
    excluded_product = create(:product, user: seller)
    variant_product = create(:product, user: seller)
    excluded_variant = create(:variant, variant_category: create(:variant_category, link: variant_product))
    workflow = create(
      :workflow,
      seller:,
      link: product,
      published_at: 3.days.ago,
      not_bought_products: [excluded_product.unique_permalink],
      not_bought_variants: [excluded_variant.external_id]
    )
    installment = create(
      :workflow_installment,
      workflow:,
      seller:,
      link: product,
      published_at: workflow.published_at,
      is_for_new_customers_of_workflow: true
    )
    installment.installment_rule.update!(delayed_delivery_time: 7.days)
    email_sequence = 0
    add_resubscribed_membership = lambda do |excluded_by: nil|
      email_sequence += 1
      subscription = create(:subscription, link: product)
      purchase = create(
        :free_purchase,
        link: product,
        subscription:,
        is_original_subscription_purchase: true,
        email: "resubscribed-member-#{email_sequence}@example.com",
        created_at: 10.days.ago
      )
      create(:subscription_event, subscription:, event_type: :deactivated, occurred_at: 9.days.ago)
      create(:subscription_event, subscription:, event_type: :restarted, occurred_at: 1.day.ago)
      if excluded_by == :product
        create(:free_purchase, link: excluded_product, email: purchase.email)
      elsif excluded_by == :variant
        excluded_purchase = create(:free_purchase, link: variant_product, email: purchase.email)
        excluded_purchase.variant_attributes << excluded_variant
      end
      purchase
    end
    included_purchase = add_resubscribed_membership.call
    product_excluded_purchase = add_resubscribed_membership.call(excluded_by: :product)
    variant_excluded_purchase = add_resubscribed_membership.call(excluded_by: :variant)

    count_queries = lambda do
      fresh_installment = Installment.find(installment.id)
      fresh_installment.workflow
      fresh_installment.installment_rule
      count = 0
      subscriber = lambda do |*, payload|
        count += 1 unless payload[:name] == "SCHEMA" || payload[:cached]
      end
      ActiveRecord::Base.uncached do
        ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
          described_class.new.send(
            :reschedule_pending_resubscribed_memberships,
            fresh_installment,
            3.days.to_i,
            cutoff_reference_time
          )
        end
      end
      count
    end

    baseline = count_queries.call
    expect(SendWorkflowInstallmentRescheduleJob.jobs.map { _1["args"][2] }).to contain_exactly(included_purchase.id)

    SendWorkflowInstallmentRescheduleJob.jobs.clear
    additional_purchases = 3.times.map { add_resubscribed_membership.call }

    expect(count_queries.call).to eq(baseline)
    expect(SendWorkflowInstallmentRescheduleJob.jobs.map { _1["args"][2] }).to contain_exactly(
      included_purchase.id,
      *additional_purchases.map(&:id)
    )
    expect(SendWorkflowInstallmentRescheduleJob.jobs.map { _1["args"][2] }).not_to include(
      product_excluded_purchase.id,
      variant_excluded_purchase.id
    )
  end

  it "releases the primary connection after execution" do
    intent = create_intent
    expect(ActiveRecord::Base.connection).to receive(:stick_to_primary!).at_least(:once).and_call_original
    expect_any_instance_of(Workflow).to receive(:schedule_installment).and_return(:not_applicable)
    expect(Makara::Context).to receive(:release_all)

    described_class.new.perform(intent.token)
  end
end
