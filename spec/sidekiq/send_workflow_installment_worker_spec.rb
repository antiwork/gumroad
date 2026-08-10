# frozen_string_literal: true

describe SendWorkflowInstallmentWorker do
  before do
    @product = create(:product)
  end

  it "does not suppress delivery jobs at enqueue time" do
    expect(described_class.sidekiq_options["lock"]).to be_nil
    expect(SendWorkflowInstallmentRescheduleJob.sidekiq_options["lock"]).to be_nil
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

    it "does not call mailer if different version" do
      expect(PostSendgridApi).not_to receive(:process)
      expect do
        SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version + 1, @purchase.id, nil, nil)
      end.to raise_error(SendWorkflowInstallmentWorker::RuleNotCommittedError)
    end

    it "reschedules a queued version after a newer version commits" do
      stale_version = @installment_rule.version
      @installment_rule.update!(delayed_delivery_time: 2.days)
      reference_time = @purchase.created_at.change(usec: 0)

      expect do
        described_class.new.perform(@installment.id, stale_version, @purchase.id, nil, nil)
      end.to change(SendWorkflowInstallmentRescheduleJob.jobs, :size).by(1)

      expect(SendWorkflowInstallmentRescheduleJob).to have_enqueued_sidekiq_job(
        @installment.id,
        @installment_rule.version,
        @purchase.id,
        nil,
        nil,
        nil,
        reference_time.iso8601
      ).immediately
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

  describe "purchase installment reschedules" do
    before do
      @reschedule_seller = create(:user)
      @reschedule_product = create(:product, user: @reschedule_seller, price_cents: 0)
      @reschedule_workflow = create(:workflow, seller: @reschedule_seller, link: @reschedule_product)
      @reschedule_installment = create(
        :installment,
        seller: @reschedule_seller,
        link: @reschedule_product,
        workflow: @reschedule_workflow,
        published_at: 3.days.ago,
        installment_type: Installment::PRODUCT_TYPE
      )
      @reschedule_rule = create(:installment_rule, installment: @reschedule_installment, delayed_delivery_time: 1.day)
      @reschedule_purchase = create(:free_purchase, link: @reschedule_product, created_at: 2.days.ago)
      @reschedule_purchase.add_to_audience_member_details
      @reschedule_reference_time = @reschedule_purchase.created_at.change(usec: 0)
    end

    it "delivers a same-version reschedule" do
      expect(PostSendgridApi).to receive(:process).with(
        post: @reschedule_installment,
        recipients: [{ email: @reschedule_purchase.email, purchase: @reschedule_purchase }],
        cache: {}
      )

      described_class.new.perform(
        @reschedule_installment.id,
        @reschedule_rule.version,
        @reschedule_purchase.id,
        nil,
        nil,
        nil,
        @reschedule_reference_time.iso8601
      )
    end

    it "does not restore a purchase that left the audience" do
      stale_version = @reschedule_rule.version
      @reschedule_rule.update!(delayed_delivery_time: 2.days)
      @reschedule_purchase.update!(stripe_refunded: true)

      expect do
        described_class.new.perform(
          @reschedule_installment.id,
          stale_version,
          @reschedule_purchase.id,
          nil,
          nil,
          nil,
          @reschedule_reference_time.iso8601
        )
      end.not_to change(SendWorkflowInstallmentRescheduleJob.jobs, :size)
    end

    it "reschedules a resubscribed membership from its adjusted reference time" do
      subscription = create(:subscription, link: @reschedule_product)
      purchase = create(
        :free_purchase,
        link: @reschedule_product,
        subscription:,
        is_original_subscription_purchase: true,
        email: "resubscribed@example.com",
        created_at: 10.days.ago
      )
      create(:subscription_event, subscription:, event_type: :deactivated, occurred_at: 9.days.ago)
      create(:subscription_event, subscription:, event_type: :restarted, occurred_at: 1.day.ago)
      purchase.add_to_audience_member_details
      stale_version = @reschedule_rule.version
      @reschedule_rule.update!(delayed_delivery_time: 3.days)
      reference_time = @reschedule_installment.workflow_delivery_reference_time(purchase).change(usec: 0)

      described_class.new.perform(
        @reschedule_installment.id,
        stale_version,
        purchase.id,
        nil,
        nil,
        nil,
        reference_time.iso8601
      )

      expect(SendWorkflowInstallmentRescheduleJob).to have_enqueued_sidekiq_job(
        @reschedule_installment.id,
        @reschedule_rule.version,
        purchase.id,
        nil,
        nil,
        nil,
        reference_time.iso8601
      ).at(reference_time + @reschedule_rule.delayed_delivery_time)
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
      SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, nil, @follower.id, nil)
      expect(PostSendgridApi).to have_received(:process).with(
        post: @installment,
        recipients: [{ email: @follower.email, follower: @follower, url_redirect: UrlRedirect.find_by(installment: @installment) }],
        cache: {}
      )
    end

    it "calls the follower mailer for the matching confirmation" do
      allow(PostSendgridApi).to receive(:process)

      described_class.new.perform(
        @installment.id,
        @installment_rule.version,
        nil,
        @follower.id,
        nil,
        nil,
        @follower.confirmed_at.change(usec: 0).iso8601
      )

      expect(PostSendgridApi).to have_received(:process)
    end

    it "does not attach a same-version job to a later confirmation" do
      old_reference_time = @follower.confirmed_at.change(usec: 0)
      @follower.update!(confirmed_at: 1.hour.from_now)
      expect(PostSendgridApi).not_to receive(:process)

      described_class.new.perform(
        @installment.id,
        @installment_rule.version,
        nil,
        @follower.id,
        nil,
        nil,
        old_reference_time.iso8601
      )
    end

    it "does not let a purchase mask a follower outside the workflow dates" do
      product = create(:product, user: @user, price_cents: 0)
      purchase = create(:free_purchase, link: product, email: @follower.email, created_at: 1.day.ago)
      purchase.add_to_audience_member_details
      @installment.update!(created_after: 2.days.ago)
      @follower.update_columns(created_at: 3.days.ago, confirmed_at: 1.hour.ago.change(usec: 0))
      expect(PostSendgridApi).not_to receive(:process)

      described_class.new.perform(
        @installment.id,
        @installment_rule.version,
        nil,
        @follower.id,
        nil,
        nil,
        @follower.confirmed_at.iso8601
      )
    end

    it "matches a follower in range when the required purchase predates the range" do
      product = create(:product, user: @user, price_cents: 0)
      purchase = create(:free_purchase, link: product, email: @follower.email, created_at: 3.days.ago)
      purchase.add_to_audience_member_details
      @installment.update!(created_after: 2.days.ago, bought_products: [product.unique_permalink])
      @follower.update_columns(created_at: 1.day.ago, confirmed_at: 1.hour.ago.change(usec: 0))
      allow(PostSendgridApi).to receive(:process)

      described_class.new.perform(
        @installment.id,
        @installment_rule.version,
        nil,
        @follower.id,
        nil,
        nil,
        @follower.confirmed_at.iso8601
      )

      expect(PostSendgridApi).to have_received(:process)
    end

    it "fills an expired cache from the locked primary" do
      $redis.del(
        RedisKey.workflow_installment_rule_version(@installment.id),
        RedisKey.workflow_installment_rule_pending_token(@installment.id)
      )
      allow(PostSendgridApi).to receive(:process)
      expect(ActiveRecord::Base.connection).to receive(:stick_to_primary!).at_least(:once).and_call_original
      expect(InstallmentRule).to receive(:lock).once.and_call_original

      SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, nil, @follower.id, nil)

      expect(PostSendgridApi).to have_received(:process)
      expect(InstallmentRule.cached_version(@installment.id)).to eq(@installment_rule.version)
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
      $redis.del(
        RedisKey.workflow_installment_rule_version(@installment.id),
        RedisKey.workflow_installment_rule_pending_token(@installment.id)
      )
      allow(PostSendgridApi).to receive(:process)
      expect(ActiveRecord::Base.connection).to receive(:stick_to_primary!).at_least(:once).and_call_original
      expect(InstallmentRule).to receive(:lock).once.and_call_original
      expect_any_instance_of(InstallmentRule).to receive(:cache_version!).once.and_raise(RedisClient::Error.new("fill failed"))
      expect(Makara::Context).to receive(:release_all).once.and_call_original

      SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, nil, @follower.id, nil)

      expect(PostSendgridApi).to have_received(:process)
    end

    it "retries an old job while a publication transition is pending" do
      InstallmentRule.cache_pending_version!(
        installment_id: @installment.id,
        version: @installment_rule.version + 1,
        token: SecureRandom.uuid
      )
      expect(PostSendgridApi).not_to receive(:process)

      expect do
        SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, nil, @follower.id, nil)
      end.to raise_error(SendWorkflowInstallmentWorker::RuleNotCommittedError)
    end

    it "drops an old job after a newer version commits" do
      stale_version = @installment_rule.version
      @installment_rule.update!(delayed_delivery_time: 2.days)
      expect(PostSendgridApi).not_to receive(:process)

      expect do
        SendWorkflowInstallmentWorker.new.perform(@installment.id, stale_version, nil, @follower.id, nil)
      end.not_to raise_error
    end

    it "honors a newer pending version that appears during a cache fill" do
      version_key = RedisKey.workflow_installment_rule_version(@installment.id)
      owner_key = RedisKey.workflow_installment_rule_pending_token(@installment.id)
      newer_version = @installment_rule.version + 1
      $redis.del(version_key, owner_key)
      allow_any_instance_of(InstallmentRule).to receive(:cache_version!).and_wrap_original do |method, *args, **kwargs|
        InstallmentRule.cache_pending_version!(
          installment_id: @installment.id,
          version: newer_version,
          token: SecureRandom.uuid
        )
        method.call(*args, **kwargs)
      end
      expect(PostSendgridApi).not_to receive(:process)

      expect do
        SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, nil, @follower.id, nil)
      end.to raise_error(SendWorkflowInstallmentWorker::RuleNotCommittedError)
      expect(InstallmentRule.cached_version(@installment.id)).to eq(newer_version)
    end

    it "retries while a pending version outlives its owner" do
      version_key = RedisKey.workflow_installment_rule_version(@installment.id)
      owner_key = RedisKey.workflow_installment_rule_pending_token(@installment.id)
      $redis.set(version_key, @installment_rule.version + 1)
      $redis.del(owner_key)
      expect(PostSendgridApi).not_to receive(:process)

      expect do
        SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, nil, @follower.id, nil)
      end.to raise_error(SendWorkflowInstallmentWorker::RuleNotCommittedError)
    end

    it "retries while only pending ownership remains" do
      version_key = RedisKey.workflow_installment_rule_version(@installment.id)
      owner_key = RedisKey.workflow_installment_rule_pending_token(@installment.id)
      $redis.del(version_key)
      $redis.set(owner_key, SecureRandom.uuid)
      expect(PostSendgridApi).not_to receive(:process)

      expect do
        SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, nil, @follower.id, nil)
      end.to raise_error(SendWorkflowInstallmentWorker::RuleNotCommittedError)
    end

    it "reschedules a stale follower job from its confirmation time" do
      @follower.update_columns(created_at: 3.days.ago, confirmed_at: 2.hours.ago)
      reference_time = @follower.confirmed_at.change(usec: 0)
      stale_version = @installment_rule.version
      @installment_rule.update!(delayed_delivery_time: 2.days)

      expect do
        described_class.new.perform(@installment.id, stale_version, nil, @follower.id, nil)
      end.to change(SendWorkflowInstallmentRescheduleJob.jobs, :size).by(1)

      expect(SendWorkflowInstallmentRescheduleJob).to have_enqueued_sidekiq_job(
        @installment.id,
        @installment_rule.version,
        nil,
        @follower.id,
        nil,
        nil,
        reference_time.iso8601
      ).at(reference_time + @installment_rule.delayed_delivery_time)
    end

    it "does not restore a deleted follower" do
      stale_version = @installment_rule.version
      @installment_rule.update!(delayed_delivery_time: 2.days)
      @follower.mark_deleted!

      expect do
        described_class.new.perform(@installment.id, stale_version, nil, @follower.id, nil)
      end.not_to change(SendWorkflowInstallmentRescheduleJob.jobs, :size)
    end

    it "does not call mailer if different version" do
      expect(PostSendgridApi).not_to receive(:process)
      expect do
        SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version + 1, nil, @follower.id, nil)
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

  describe "affiliate_installment" do
    before do
      @seller = create(:user)
      @product = create(:product, user: @seller, price_cents: 0)
      @affiliate = create(:direct_affiliate, seller: @seller, send_posts: true, created_at: 1.day.ago)
      @reference_time = 1.hour.ago.change(usec: 0)
      @product_affiliate = create(
        :product_affiliate,
        affiliate: @affiliate,
        product: @product,
        created_at: @reference_time
      )
      @workflow = create(
        :workflow,
        seller: @seller,
        link: nil,
        workflow_type: Workflow::AFFILIATE_TYPE,
        published_at: 2.days.ago
      )
      @installment = create(
        :installment,
        seller: @seller,
        workflow: @workflow,
        installment_type: Installment::AFFILIATE_TYPE,
        affiliate_products: [@product.unique_permalink],
        published_at: @workflow.published_at
      )
      @installment_rule = create(:installment_rule, installment: @installment, delayed_delivery_time: 1.day)
    end

    it "sends for the current product assignment" do
      expect_any_instance_of(Installment).to receive(:send_installment_from_workflow_for_affiliate_user).with(@affiliate.affiliate_user_id)

      perform_affiliate_job
    end

    it "does not send after the product assignment is removed" do
      @product_affiliate.destroy!
      expect_any_instance_of(Installment).not_to receive(:send_installment_from_workflow_for_affiliate_user)

      perform_affiliate_job
    end

    it "sends when an equivalent product assignment remains" do
      other_product = create(:product, user: @seller)
      create(:product_affiliate, affiliate: @affiliate, product: other_product, created_at: @reference_time)
      @installment.update!(affiliate_products: [])
      @product_affiliate.destroy!
      expect_any_instance_of(Installment).to receive(:send_installment_from_workflow_for_affiliate_user).with(@affiliate.affiliate_user_id)

      perform_affiliate_job
    end

    it "does not send after the affiliate is deleted" do
      @affiliate.mark_deleted!
      expect_any_instance_of(Installment).not_to receive(:send_installment_from_workflow_for_affiliate_user)

      perform_affiliate_job
    end

    it "does not send after the affiliate opts out" do
      @affiliate.update_posts_subscription(send_posts: false)
      expect_any_instance_of(Installment).not_to receive(:send_installment_from_workflow_for_affiliate_user)

      perform_affiliate_job
    end

    it "does not send after the assignment time changes" do
      @product_affiliate.update_columns(created_at: 30.minutes.ago)
      expect_any_instance_of(Installment).not_to receive(:send_installment_from_workflow_for_affiliate_user)

      perform_affiliate_job
    end

    it "does not send outside the workflow product scope" do
      other_product = create(:product, user: @seller)
      @installment.update!(affiliate_products: [other_product.unique_permalink])
      expect_any_instance_of(Installment).not_to receive(:send_installment_from_workflow_for_affiliate_user)

      perform_affiliate_job
    end

    it "reschedules a stale affiliate job from its product assignment time" do
      stale_version = @installment_rule.version
      @installment_rule.update!(delayed_delivery_time: 2.days)

      expect do
        described_class.new.perform(@installment.id, stale_version, nil, nil, @affiliate.affiliate_user_id)
      end.to change(SendWorkflowInstallmentRescheduleJob.jobs, :size).by(1)

      expect(SendWorkflowInstallmentRescheduleJob).to have_enqueued_sidekiq_job(
        @installment.id,
        @installment_rule.version,
        nil,
        nil,
        @affiliate.affiliate_user_id,
        nil,
        @reference_time.iso8601
      ).at(@reference_time + @installment_rule.delayed_delivery_time)
    end

    it "does not restore a removed product assignment" do
      stale_version = @installment_rule.version
      @installment_rule.update!(delayed_delivery_time: 2.days)
      @product_affiliate.destroy!

      expect do
        described_class.new.perform(@installment.id, stale_version, nil, nil, @affiliate.affiliate_user_id)
      end.not_to change(SendWorkflowInstallmentRescheduleJob.jobs, :size)
    end

    def perform_affiliate_job
      described_class.new.perform(
        @installment.id,
        @installment_rule.version,
        nil,
        nil,
        @affiliate.affiliate_user_id,
        nil,
        @reference_time.iso8601
      )
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

    it "reschedules a stale cancellation email from its deactivation time" do
      stale_version = @installment_rule.version
      @installment_rule.update!(delayed_delivery_time: 3.days)
      reference_time = @subscription.deactivated_at.change(usec: 0)

      described_class.new.perform(
        @installment.id,
        stale_version,
        nil,
        nil,
        nil,
        @subscription.id,
        reference_time.iso8601
      )

      expect(SendWorkflowInstallmentRescheduleJob).to have_enqueued_sidekiq_job(
        @installment.id,
        @installment_rule.version,
        nil,
        nil,
        nil,
        @subscription.id,
        reference_time.iso8601
      ).at(reference_time + @installment_rule.delayed_delivery_time)
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
