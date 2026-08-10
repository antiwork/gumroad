# frozen_string_literal: true

describe SendWorkflowInstallmentWorker do
  before do
    @product = create(:product)
  end

  describe "purchase_installment" do
    before do
      @workflow = create(:workflow, seller: @product.user, link: @product, created_at: Time.current)
      @installment = create(:installment, link: @product, workflow: @workflow, published_at: Time.current)
      @installment_rule = create(:installment_rule, installment: @installment, delayed_delivery_time: 1.day)
      @purchase = create(:purchase, link: @product, created_at: 1.week.ago, price_cents: 100)
    end

    it "calls purchase mailer if same version" do
      expect(PostSendgridApi).to receive(:process).with(
        post: @installment,
        recipients: [{ email: @purchase.email, purchase: @purchase }],
        cache: {}
      )
      SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, @purchase.id, nil, nil)
    end

    it "reads the primary database if the shared version expires" do
      $redis.del(RedisKey.workflow_installment_rule_version(@installment.id))
      allow(PostSendgridApi).to receive(:process)
      expect(ActiveRecord::Base.connection).to receive(:stick_to_primary!).at_least(:once).and_call_original

      SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, @purchase.id, nil, nil)

      expect(PostSendgridApi).to have_received(:process)
    end

    it "retries if the queued version is not visible" do
      pending_version = @installment_rule.version + 1
      $redis.set(RedisKey.workflow_installment_rule_version(@installment.id), pending_version)
      expect(PostSendgridApi).not_to receive(:process)
      expect(ActiveRecord::Base.connection).to receive(:stick_to_primary!).at_least(:once).and_call_original

      expect do
        SendWorkflowInstallmentWorker.new.perform(@installment.id, pending_version, @purchase.id, nil, nil)
      end.to raise_error(SendWorkflowInstallmentWorker::RuleNotCommittedError)
    end

    it "retries an old job while a publication transition is pending" do
      $redis.set(RedisKey.workflow_installment_rule_version(@installment.id), @installment_rule.version + 1)
      expect(PostSendgridApi).not_to receive(:process)

      expect do
        SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, @purchase.id, nil, nil)
      end.to raise_error(SendWorkflowInstallmentWorker::RuleNotCommittedError)
    end

    it "drops a queued version after a newer version commits" do
      stale_version = @installment_rule.version
      @installment_rule.update!(delayed_delivery_time: 2.days)
      expect(PostSendgridApi).not_to receive(:process)

      SendWorkflowInstallmentWorker.new.perform(@installment.id, stale_version, @purchase.id, nil, nil)
    end

    it "does not call mailer if deleted installment" do
      @installment.update_attribute(:deleted_at, Time.current)
      expect(PostSendgridApi).not_to receive(:process)
      SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, @purchase.id, nil, nil)
    end

    it "does not call mailer if workflow is deleted" do
      @workflow.update_attribute(:deleted_at, Time.current)
      expect(PostSendgridApi).not_to receive(:process)
      SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, @purchase.id, nil, nil)
    end

    it "does not call mailer if installment is not published" do
      @installment.update_attribute(:published_at, nil)
      expect(PostSendgridApi).not_to receive(:process)
      SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, @purchase.id, nil, nil)
    end

    it "does not call mailer if installment is not found" do
      expect(PostSendgridApi).not_to receive(:process)
      SendWorkflowInstallmentWorker.new.perform("non-existing-installment-id", @installment_rule.version, @purchase.id, nil, nil)
    end

    it "does not call mailer if seller is suspended" do
      admin_user = create(:admin_user)
      @product.user.flag_for_fraud!(author_id: admin_user.id)
      @product.user.suspend_for_fraud!(author_id: admin_user.id)

      expect(PostSendgridApi).not_to receive(:process)
      SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, @purchase.id, nil, nil)
    end

    it "does not call any mailer if both purchase_id and follower_id are passed" do
      expect(PostSendgridApi).not_to receive(:process)
      SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, @purchase.id, @purchase.id, nil)
    end

    it "does not call any mailer if both purchase_id and affiliate_user_id are passed" do
      expect(PostSendgridApi).not_to receive(:process)
      SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, @purchase.id, nil, @purchase.id)
    end

    it "does not call any mailer if both follower_id and affiliate_user_id are passed" do
      expect(PostSendgridApi).not_to receive(:process)
      SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, nil, @purchase.id, @purchase.id)
    end

    it "does not call any mailer if purchase_id, follower_id and affiliate_user_id are passed" do
      expect(PostSendgridApi).not_to receive(:process)
      SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, @purchase.id, @purchase.id, @purchase.id)
    end

    it "does not call any mailer if neither purchase_id nor follower_id nor affiliate_user_id are passed" do
      expect(PostSendgridApi).not_to receive(:process)
      SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, nil, nil, nil)
    end
  end

  describe "follower_installment" do
    before do
      @user = create(:user)
      @workflow = create(:workflow, seller: @user, link: nil, created_at: Time.current, workflow_type: Workflow::AUDIENCE_TYPE)
      @installment = create(:follower_installment, seller: @user, workflow: @workflow, published_at: Time.current)
      @installment_rule = create(:installment_rule, installment: @installment, delayed_delivery_time: 1.day)
      @follower = create(:active_follower, followed_id: @user.id, email: "some@email.com")
    end

    it "calls follower mailer if same version" do
      allow(PostSendgridApi).to receive(:process)
      expect(InstallmentRule).not_to receive(:find_by)
      SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, nil, @follower.id, nil)
      expect(PostSendgridApi).to have_received(:process).with(
        post: @installment,
        recipients: [{ email: @follower.email, follower: @follower, url_redirect: UrlRedirect.find_by(installment: @installment) }],
        cache: {}
      )
    end

    it "uses the locked primary version if the Redis read fails" do
      allow(PostSendgridApi).to receive(:process)
      expect(InstallmentRule).to receive(:cached_version_state).with(@installment.id).once.and_raise(Redis::BaseError.new("read failed"))
      expect(ActiveRecord::Base.connection).to receive(:stick_to_primary!).at_least(:once).and_call_original
      expect(InstallmentRule).to receive(:lock).once.and_call_original
      expect_any_instance_of(InstallmentRule).not_to receive(:cache_version!)
      expect(Makara::Context).to receive(:release_all).once.and_call_original

      SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, nil, @follower.id, nil)

      expect(PostSendgridApi).to have_received(:process)
    end

    it "uses the locked primary version if the Redis cache fill fails" do
      $redis.del(RedisKey.workflow_installment_rule_version(@installment.id))
      allow(PostSendgridApi).to receive(:process)
      expect(ActiveRecord::Base.connection).to receive(:stick_to_primary!).at_least(:once).and_call_original
      expect(InstallmentRule).to receive(:lock).once.and_call_original
      expect_any_instance_of(InstallmentRule).to receive(:cache_version!).once.and_raise(RedisClient::Error.new("fill failed"))
      expect(Makara::Context).to receive(:release_all).once.and_call_original

      SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, nil, @follower.id, nil)

      expect(PostSendgridApi).to have_received(:process)
    end

    it "retries if the queued version is not visible" do
      expect(PostSendgridApi).not_to receive(:process)
      expect do
        SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version + 1, nil, @follower.id, nil)
      end.to raise_error(SendWorkflowInstallmentWorker::RuleNotCommittedError)
    end

    it "honors a newer pending version that appears while filling a cache miss" do
      version_key = RedisKey.workflow_installment_rule_version(@installment.id)
      newer_version = @installment_rule.version + 1
      $redis.del(version_key)
      allow_any_instance_of(InstallmentRule).to receive(:cache_version!).and_wrap_original do |method, *args, **kwargs|
        $redis.set(version_key, newer_version)
        method.call(*args, **kwargs)
      end
      expect(InstallmentRule).to receive(:lock).and_call_original
      expect(PostSendgridApi).not_to receive(:process)

      expect do
        SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, nil, @follower.id, nil)
      end.to raise_error(SendWorkflowInstallmentWorker::RuleNotCommittedError)
      expect(InstallmentRule.cached_version(@installment.id)).to eq(newer_version)
    end

    it "retries while a pending version outlives its owner" do
      version_key = RedisKey.workflow_installment_rule_version(@installment.id)
      pending_token_key = RedisKey.workflow_installment_rule_pending_token(@installment.id)
      $redis.set(version_key, @installment_rule.version + 1)
      $redis.del(pending_token_key)
      expect(PostSendgridApi).not_to receive(:process)

      expect do
        SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, nil, @follower.id, nil)
      end.to raise_error(SendWorkflowInstallmentWorker::RuleNotCommittedError)
    end

    it "locks the primary after pending cache protection expires" do
      version_key = RedisKey.workflow_installment_rule_version(@installment.id)
      pending_token_key = RedisKey.workflow_installment_rule_pending_token(@installment.id)
      $redis.set(version_key, @installment_rule.version + 1)
      $redis.set(pending_token_key, SecureRandom.uuid)
      $redis.del(version_key, pending_token_key)
      allow(PostSendgridApi).to receive(:process)
      expect(InstallmentRule).to receive(:lock).and_call_original

      SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, nil, @follower.id, nil)

      expect(PostSendgridApi).to have_received(:process)
      expect(InstallmentRule.cached_version(@installment.id)).to eq(@installment_rule.version)
    end

    it "retries if only pending ownership remains" do
      version_key = RedisKey.workflow_installment_rule_version(@installment.id)
      pending_token_key = RedisKey.workflow_installment_rule_pending_token(@installment.id)
      $redis.del(version_key)
      $redis.set(pending_token_key, SecureRandom.uuid)
      expect(PostSendgridApi).not_to receive(:process)

      expect do
        SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, nil, @follower.id, nil)
      end.to raise_error(SendWorkflowInstallmentWorker::RuleNotCommittedError)
    end

    it "does not call mailer if deleted installment" do
      @installment.update_attribute(:deleted_at, Time.current)
      expect(PostSendgridApi).not_to receive(:process)
      SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, nil, @follower.id, nil)
    end

    it "does not call mailer if workflow is deleted" do
      @workflow.update_attribute(:deleted_at, Time.current)
      expect(PostSendgridApi).not_to receive(:process)
      SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, nil, @follower.id, nil)
    end

    it "does not call mailer if installment is not published" do
      @installment.update_attribute(:published_at, nil)
      expect(PostSendgridApi).not_to receive(:process)
      SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, nil, @follower.id, nil)
    end
  end

  describe "member_cancellation_installment" do
    before do
      @creator = create(:user)
      @product = create(:subscription_product, user: @creator)
      @subscription = create(:subscription, link: @product, cancelled_by_buyer: true, cancelled_at: 2.days.ago, deactivated_at: 1.day.ago)
      @workflow = create(:workflow, seller: @creator, link: @product, workflow_trigger: "member_cancellation")
      @installment = create(:published_installment, link: @product, workflow: @workflow, workflow_trigger: "member_cancellation")
      @installment_rule = create(:installment_rule, installment: @installment, delayed_delivery_time: 1.day)
      @sale = create(:purchase, is_original_subscription_purchase: true, link: @product, subscription: @subscription, email: "test@gmail.com", created_at: 1.week.ago, price_cents: 100)
    end

    it "calls cancellation mailer if given subscription id" do
      expect(PostSendgridApi).to receive(:process).with(
        post: @installment,
        recipients: [{ email: @sale.email, purchase: @sale, subscription: @subscription }],
        cache: {}
      )
      SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, nil, nil, nil, @subscription.id)
    end
  end

  it "caches template rendering" do
    @workflow = create(:workflow, seller: @product.user, link: @product, created_at: Time.current)
    @installment = create(:installment, link: @product, workflow: @workflow, published_at: Time.current)
    @installment_rule = create(:installment_rule, installment: @installment, delayed_delivery_time: 1.day)
    @purchase_1 = create(:purchase, link: @product, created_at: 1.week.ago)
    @purchase_2 = create(:purchase, link: @product, created_at: 1.week.ago)

    expect(PostSendgridApi).to receive(:process).with(
      post: @installment,
      recipients: [{ email: @purchase_1.email, purchase: @purchase_1 }],
      cache: {}
    ).and_call_original
    expect(PostSendgridApi).to receive(:process).with(
      post: @installment,
      recipients: [{ email: @purchase_2.email, purchase: @purchase_2 }],
      cache: { @installment => anything }
    ).and_call_original

    SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, @purchase_1.id, nil, nil)
    SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, @purchase_2.id, nil, nil)

    expect(PostSendgridApi.mails.size).to eq(2)
    expect(PostSendgridApi.mails[@purchase_1.email]).to be_present
    expect(PostSendgridApi.mails[@purchase_2.email]).to be_present
  end

  it "logs instead of silently doing nothing when no recipient id is given" do
    @workflow = create(:workflow, seller: @product.user, link: @product, created_at: Time.current)
    @installment = create(:installment, link: @product, workflow: @workflow, published_at: Time.current)
    @installment_rule = create(:installment_rule, installment: @installment, delayed_delivery_time: 1.day)

    expect(Rails.logger).to receive(:error).with(/could not|unusable recipient combination/)

    SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, nil, nil, nil, nil)

    expect(PostSendgridApi.mails).to be_empty
  end
end
