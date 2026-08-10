# frozen_string_literal: true

describe "workflow installment schedule intent completion", :freeze_time do
  def create_intent(installment:, rule:, processed_at: nil)
    WorkflowInstallmentScheduleIntent.create!(
      token: SecureRandom.uuid,
      installment_id: installment.id,
      rule_version: rule.version,
      cutoff_reference_time: Time.current,
      processed_at:
    )
  end

  describe SendWorkflowPostEmailsJob do
    let(:seller) { create(:named_user) }
    let(:workflow) { create(:audience_workflow, seller:) }
    let(:post) { create(:audience_post, :published, workflow:, seller:) }
    let(:rule) { create(:post_rule, installment: post, delayed_delivery_time: 1.day) }
    let!(:follower) { create(:active_follower, user: seller, created_at: 2.days.ago) }

    it "marks an intent processed when the fanout starts" do
      intent = create_intent(installment: post, rule:)

      described_class.new.perform(post.id, nil, false, rule.version, intent.token)

      expect(intent.reload.processed_at).to be_present
      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(post.id, rule.version, nil, follower.id, nil)
    end

    it "continues a retry after the intent is processed" do
      intent = create_intent(installment: post, rule:, processed_at: 1.minute.ago)

      described_class.new.perform(post.id, nil, false, rule.version, intent.token)

      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(post.id, rule.version, nil, follower.id, nil)
    end
  end

  describe SendWorkflowEmailsToPastCanceledMembersJob do
    let(:seller) { create(:user) }
    let(:product) { create(:subscription_product, user: seller) }
    let(:workflow) do
      create(
        :workflow,
        seller:,
        link: product,
        workflow_trigger: Workflow::MEMBER_CANCELLATION_WORKFLOW_TRIGGER,
        send_to_past_customers: true
      )
    end
    let(:installment) do
      create(
        :published_installment,
        link: product,
        workflow:,
        workflow_trigger: Workflow::MEMBER_CANCELLATION_WORKFLOW_TRIGGER
      )
    end
    let(:rule) { create(:installment_rule, installment:, delayed_delivery_time: 14.days) }
    let(:subscription) { create(:subscription, link: product, cancelled_at: 30.days.ago, deactivated_at: 30.days.ago) }
    let!(:purchase) do
      create(
        :free_purchase,
        is_original_subscription_purchase: true,
        link: product,
        subscription:,
        created_at: 60.days.ago
      )
    end

    it "marks an intent processed when the fanout starts" do
      intent = create_intent(installment:, rule:)

      described_class.new.perform(installment.id, nil, nil, rule.version, intent.token)

      expect(intent.reload.processed_at).to be_present
      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(installment.id, rule.version, nil, nil, nil, subscription.id)
    end

    it "continues a retry after the intent is processed" do
      intent = create_intent(installment:, rule:, processed_at: 1.minute.ago)

      described_class.new.perform(installment.id, nil, nil, rule.version, intent.token)

      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(installment.id, rule.version, nil, nil, nil, subscription.id)
    end
  end
end
