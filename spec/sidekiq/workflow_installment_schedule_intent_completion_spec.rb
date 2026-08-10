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

  def claim_fanout(intent)
    intent.with_lock { intent.claim_fanout! }
  end

  describe SendWorkflowPostEmailsJob do
    let(:seller) { create(:named_user) }
    let(:workflow) { create(:audience_workflow, seller:) }
    let(:post) { create(:audience_post, :published, workflow:, seller:) }
    let(:rule) { create(:post_rule, installment: post, delayed_delivery_time: 1.day) }
    let!(:follower) { create(:active_follower, user: seller, created_at: 2.days.ago) }

    it "marks an intent processed after the fanout completes" do
      intent = create_intent(installment: post, rule:)
      fanout_token = claim_fanout(intent)

      described_class.new.perform(post.id, nil, false, rule.version, intent.token, fanout_token)

      expect(intent.reload.processed_at).to be_present
      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(
        post.id,
        rule.version,
        nil,
        follower.id,
        nil,
        nil,
        follower.confirmed_at.change(usec: 0).iso8601
      )
    end

    it "keeps a partial fanout recoverable" do
      create(:active_follower, user: seller, created_at: 1.day.ago)
      intent = create_intent(installment: post, rule:)
      fanout_token = claim_fanout(intent)
      attempts = 0
      allow(SendWorkflowInstallmentWorker).to receive(:perform_at) do
        attempts += 1
        raise "Redis is unavailable" if attempts == 2

        "jid"
      end

      expect do
        described_class.new.perform(post.id, nil, false, rule.version, intent.token, fanout_token)
      end.to raise_error("Redis is unavailable")

      expect(attempts).to eq(2)
      expect(intent.reload.processed_at).to be_nil

      allow(SendWorkflowInstallmentWorker).to receive(:perform_at).and_return("jid")
      described_class.new.perform(post.id, nil, false, rule.version, intent.token, fanout_token)

      expect(intent.reload.processed_at).to be_present
    end

    it "keeps the intent pending when middleware cancels a recipient enqueue" do
      intent = create_intent(installment: post, rule:)
      fanout_token = claim_fanout(intent)
      allow(SendWorkflowInstallmentWorker).to receive(:perform_at).and_return(nil)

      expect do
        described_class.new.perform(post.id, nil, false, rule.version, intent.token, fanout_token)
      end.to raise_error(SendWorkflowPostEmailsJob::FanoutNotEnqueuedError)

      expect(intent.reload.processed_at).to be_nil
    end

    it "does not rerun a completed fanout" do
      intent = create_intent(installment: post, rule:, processed_at: 1.minute.ago)

      described_class.new.perform(post.id, nil, false, rule.version, intent.token, SecureRandom.uuid)

      expect(SendWorkflowInstallmentWorker.jobs).to be_empty
    end

    it "completes an intent when the installment no longer exists" do
      intent = create_intent(installment: post, rule:)
      fanout_token = claim_fanout(intent)
      post.delete

      described_class.new.perform(post.id, nil, false, rule.version, intent.token, fanout_token)

      expect(intent.reload.processed_at).to be_present
    end

    it "completes an intent when the rule no longer exists" do
      intent = create_intent(installment: post, rule:)
      fanout_token = claim_fanout(intent)
      rule.delete

      described_class.new.perform(post.id, nil, false, rule.version, intent.token, fanout_token)

      expect(intent.reload.processed_at).to be_present
    end

    it "does not run a stale copy while another fanout owns the intent" do
      intent = create_intent(installment: post, rule:)
      current_token = claim_fanout(intent)

      described_class.new.perform(post.id, nil, false, rule.version, intent.token, SecureRandom.uuid)

      expect(SendWorkflowInstallmentWorker.jobs).to be_empty
      expect(intent.reload.processed_at).to be_nil
      expect(intent.fanout_token).to eq(current_token)
    end

    it "renews its lease before and after the audience query" do
      intent = create_intent(installment: post, rule:)
      fanout_token = claim_fanout(intent)
      events = []
      allow(WorkflowInstallmentScheduleIntent).to receive(:renew_fanout).and_wrap_original do |method, **kwargs|
        events << :renew
        method.call(**kwargs)
      end
      allow(Makara::Context).to receive(:release_all).and_wrap_original do |method|
        events << :release
        method.call
      end
      allow(WithMaxExecutionTime).to receive(:timeout_queries).and_wrap_original do |method, *args, **kwargs, &block|
        events << :query
        result = method.call(*args, **kwargs, &block)
        events << :query_complete
        result
      end

      described_class.new.perform(post.id, nil, false, rule.version, intent.token, fanout_token)

      expect(events).to eq([:release, :renew, :release, :query, :query_complete, :renew, :release, :renew, :release])
      expect(intent.reload.processed_at).to be_present
    end

    it "stops after the audience query if another fanout takes ownership" do
      intent = create_intent(installment: post, rule:)
      fanout_token = claim_fanout(intent)
      replacement_token = nil
      allow(WithMaxExecutionTime).to receive(:timeout_queries).and_wrap_original do |method, *args, **kwargs, &block|
        members = method.call(*args, **kwargs, &block)
        travel WorkflowInstallmentScheduleIntent::FANOUT_LEASE + 1.second
        replacement_token = claim_fanout(intent)
        members
      end

      described_class.new.perform(post.id, nil, false, rule.version, intent.token, fanout_token)

      expect(SendWorkflowInstallmentWorker.jobs).to be_empty
      expect(intent.reload.processed_at).to be_nil
      expect(intent.fanout_token).to eq(replacement_token)
    end

    it "stops its recipient loop when a later owner takes over" do
      create(:active_follower, user: seller, created_at: 1.day.ago)
      intent = create_intent(installment: post, rule:)
      fanout_token = claim_fanout(intent)
      replacement_token = nil
      heartbeat_time = 0.0
      attempts = 0
      job = described_class.new
      allow(job).to receive(:fanout_heartbeat_time) { heartbeat_time }
      allow(SendWorkflowInstallmentWorker).to receive(:perform_at) do
        attempts += 1
        if attempts == 1
          travel WorkflowInstallmentScheduleIntent::FANOUT_LEASE + 1.second
          replacement_token = claim_fanout(intent)
          heartbeat_time += WorkflowInstallmentScheduleIntent::FANOUT_HEARTBEAT_INTERVAL.to_f + 1
        end
        "jid"
      end

      job.perform(post.id, nil, false, rule.version, intent.token, fanout_token)

      expect(attempts).to eq(1)
      expect(intent.reload.processed_at).to be_nil
      expect(intent.fanout_token).to eq(replacement_token)
    end

    it "runs a direct fanout without an intent lease" do
      rule
      expect(WorkflowInstallmentScheduleIntent).not_to receive(:renew_fanout)

      described_class.new.perform(post.id)

      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(
        post.id,
        rule.version,
        nil,
        follower.id,
        nil,
        nil,
        follower.confirmed_at.change(usec: 0).iso8601
      )
    end

    it "does not replace a missing matching purchase with another embedded purchase" do
      job = described_class.new
      job.instance_variable_set(:@post, post)
      job.instance_variable_set(:@rule_version, rule.version)
      job.instance_variable_set(:@rule_delay, rule.delayed_delivery_time)
      member = instance_double(
        AudienceMember,
        id: 1,
        details: { "purchases" => [{ "id" => 99, "created_at" => 1.day.ago.iso8601 }] }
      )

      job.send(:enqueue_email_job, member:, type: :purchase, id: nil)

      expect(SendWorkflowInstallmentWorker.jobs).to be_empty
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

    it "marks an intent processed after the fanout completes" do
      intent = create_intent(installment:, rule:)
      fanout_token = claim_fanout(intent)

      described_class.new.perform(installment.id, nil, nil, rule.version, intent.token, fanout_token)

      expect(intent.reload.processed_at).to be_present
      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(installment.id, rule.version, nil, nil, nil, subscription.id)
    end

    it "releases Makara after renewing its lease" do
      intent = create_intent(installment:, rule:)
      fanout_token = claim_fanout(intent)
      events = []
      job = described_class.new
      allow(job).to receive(:fanout_heartbeat_time).and_return(0.0, 301.0)
      allow(WorkflowInstallmentScheduleIntent).to receive(:renew_fanout).and_wrap_original do |method, **kwargs|
        events << :renew
        method.call(**kwargs)
      end
      allow(Makara::Context).to receive(:release_all).and_wrap_original do |method|
        events << :release
        method.call
      end

      job.perform(installment.id, nil, nil, rule.version, intent.token, fanout_token)

      expect(events).to eq([:release, :renew, :release])
      expect(intent.reload.processed_at).to be_present
    end

    it "keeps a partial fanout recoverable" do
      second_subscription = create(
        :subscription,
        link: product,
        cancelled_at: 20.days.ago,
        deactivated_at: 20.days.ago
      )
      create(
        :free_purchase,
        is_original_subscription_purchase: true,
        link: product,
        subscription: second_subscription,
        created_at: 50.days.ago
      )
      intent = create_intent(installment:, rule:)
      fanout_token = claim_fanout(intent)
      attempts = 0
      allow(SendWorkflowInstallmentWorker).to receive(:perform_at) do
        attempts += 1
        raise "Redis is unavailable" if attempts == 2

        "jid"
      end

      expect do
        described_class.new.perform(installment.id, nil, nil, rule.version, intent.token, fanout_token)
      end.to raise_error("Redis is unavailable")

      expect(attempts).to eq(2)
      expect(intent.reload.processed_at).to be_nil

      allow(SendWorkflowInstallmentWorker).to receive(:perform_at).and_return("jid")
      described_class.new.perform(installment.id, nil, nil, rule.version, intent.token, fanout_token)

      expect(intent.reload.processed_at).to be_present
    end

    it "keeps the intent pending when middleware cancels a recipient enqueue" do
      intent = create_intent(installment:, rule:)
      fanout_token = claim_fanout(intent)
      allow(SendWorkflowInstallmentWorker).to receive(:perform_at).and_return(nil)

      expect do
        described_class.new.perform(installment.id, nil, nil, rule.version, intent.token, fanout_token)
      end.to raise_error(SendWorkflowEmailsToPastCanceledMembersJob::FanoutNotEnqueuedError)

      expect(intent.reload.processed_at).to be_nil
    end

    it "does not rerun a completed fanout" do
      intent = create_intent(installment:, rule:, processed_at: 1.minute.ago)

      described_class.new.perform(installment.id, nil, nil, rule.version, intent.token, SecureRandom.uuid)

      expect(SendWorkflowInstallmentWorker.jobs).to be_empty
    end

    it "completes an intent when the installment no longer exists" do
      intent = create_intent(installment:, rule:)
      fanout_token = claim_fanout(intent)
      installment.delete

      described_class.new.perform(installment.id, nil, nil, rule.version, intent.token, fanout_token)

      expect(intent.reload.processed_at).to be_present
    end

    it "stops its recipient loop when a later owner takes over" do
      second_subscription = create(
        :subscription,
        link: product,
        cancelled_at: 20.days.ago,
        deactivated_at: 20.days.ago
      )
      create(
        :free_purchase,
        is_original_subscription_purchase: true,
        link: product,
        subscription: second_subscription,
        created_at: 50.days.ago
      )
      intent = create_intent(installment:, rule:)
      fanout_token = claim_fanout(intent)
      replacement_token = nil
      heartbeat_time = 0.0
      attempts = 0
      job = described_class.new
      allow(job).to receive(:fanout_heartbeat_time) { heartbeat_time }
      allow(SendWorkflowInstallmentWorker).to receive(:perform_at) do
        attempts += 1
        if attempts == 1
          travel WorkflowInstallmentScheduleIntent::FANOUT_LEASE + 1.second
          replacement_token = claim_fanout(intent)
          heartbeat_time += WorkflowInstallmentScheduleIntent::FANOUT_HEARTBEAT_INTERVAL.to_f + 1
        end
        "jid"
      end

      job.perform(installment.id, nil, nil, rule.version, intent.token, fanout_token)

      expect(attempts).to eq(1)
      expect(intent.reload.processed_at).to be_nil
      expect(intent.fanout_token).to eq(replacement_token)
    end

    it "runs a direct fanout without an intent lease" do
      rule
      expect(WorkflowInstallmentScheduleIntent).not_to receive(:renew_fanout)

      described_class.new.perform(installment.id)

      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(
        installment.id,
        rule.version,
        nil,
        nil,
        nil,
        subscription.id
      )
    end
  end
end
