# frozen_string_literal: true

describe SendWorkflowInstallmentWorker do
  before do
    @product = create(:product)
  end

  it "deduplicates only reschedule jobs until execution starts" do
    expect(described_class.sidekiq_options["lock"]).to be_nil
    expect(SendWorkflowInstallmentRescheduleJob.sidekiq_options["lock"]).to eq(:until_executing)
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
      SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version + 1, @purchase.id, nil, nil)
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
      SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version, nil, @follower.id, nil)
      expect(PostSendgridApi).to have_received(:process).with(
        post: @installment,
        recipients: [{ email: @follower.email, follower: @follower, url_redirect: UrlRedirect.find_by(installment: @installment) }],
        cache: {}
      )
    end

    it "does not call mailer if different version" do
      expect(PostSendgridApi).not_to receive(:process)
      SendWorkflowInstallmentWorker.new.perform(@installment.id, @installment_rule.version + 1, nil, @follower.id, nil)
    end

    it "reschedules a recipient from an older API reschedule with the current rule" do
      reference_time = 2.days.ago.change(usec: 0)
      stale_version = @installment_rule.version
      @installment_rule.update!(delayed_delivery_time: 3.days)
      expect(PostSendgridApi).not_to receive(:process)

      expect do
        SendWorkflowInstallmentWorker.new.perform(
          @installment.id,
          stale_version,
          nil,
          @follower.id,
          nil,
          nil,
          reference_time.iso8601
        )
      end.to change(SendWorkflowInstallmentRescheduleJob.jobs, :size).by(1)

      expect(SendWorkflowInstallmentRescheduleJob).to have_enqueued_sidekiq_job(
        @installment.id,
        @installment_rule.version,
        nil,
        @follower.id,
        nil,
        nil,
        reference_time.iso8601
      ).at(reference_time + 3.days)
    end

    it "does not reschedule a recipient who already received the email" do
      reference_time = 2.days.ago.change(usec: 0)
      stale_version = @installment_rule.version
      @installment_rule.update!(delayed_delivery_time: 3.days)
      create(:sent_post_email, post: @installment, email: @follower.email)
      expect(PostSendgridApi).not_to receive(:process)

      expect do
        SendWorkflowInstallmentWorker.new.perform(
          @installment.id,
          stale_version,
          nil,
          @follower.id,
          nil,
          nil,
          reference_time.iso8601
        )
      end.not_to change(SendWorkflowInstallmentRescheduleJob.jobs, :size)
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

  describe "purchase installment reschedules" do
    it "does not restore a purchase that left the audience" do
      seller = create(:user)
      product = create(:product, user: seller, price_cents: 0)
      workflow = create(:workflow, seller:, link: product)
      installment = create(
        :installment,
        seller:,
        link: product,
        workflow:,
        published_at: Time.current,
        installment_type: Installment::PRODUCT_TYPE
      )
      rule = create(:installment_rule, installment:, delayed_delivery_time: 1.day)
      purchase = create(:free_purchase, link: product, email: "buyer@example.com", created_at: 2.days.ago)
      create(:free_purchase, link: product, email: purchase.email, created_at: 1.day.ago)
      stale_version = rule.version
      rule.update!(delayed_delivery_time: 2.days)
      purchase.update!(stripe_refunded: true)
      expect(PostSendgridApi).not_to receive(:process)

      expect do
        described_class.new.perform(
          installment.id,
          stale_version,
          purchase.id,
          nil,
          nil,
          nil,
          purchase.created_at.iso8601
        )
      end.not_to change(SendWorkflowInstallmentRescheduleJob.jobs, :size)
    end

    it "reschedules a pending email from a resubscribed membership with its adjusted reference time" do
      seller = create(:user)
      product = create(:subscription_product, user: seller)
      subscription = create(:subscription, link: product)
      purchase = create(
        :free_purchase,
        link: product,
        subscription:,
        is_original_subscription_purchase: true,
        email: "resubscribed@example.com",
        created_at: 10.days.ago
      )
      create(:subscription_event, subscription:, event_type: :deactivated, occurred_at: 9.days.ago)
      create(:subscription_event, subscription:, event_type: :restarted, occurred_at: 1.day.ago)
      purchase.add_to_audience_member_details
      later_purchase = create(:free_purchase, link: product, email: purchase.email, created_at: Time.current)
      workflow = create(:workflow, seller:, link: product)
      installment = create(
        :installment,
        seller:,
        link: product,
        workflow:,
        published_at: Time.current,
        installment_type: Installment::PRODUCT_TYPE
      )
      rule = create(:installment_rule, installment:, delayed_delivery_time: 1.day)
      stale_version = rule.version
      rule.update!(delayed_delivery_time: 3.days)
      reference_time = installment.workflow_delivery_reference_time(purchase).change(usec: 0)
      member = AudienceMember.find_by!(seller:, email: purchase.email)
      current_match = AudienceMember.filter(
        seller_id: seller.id,
        params: installment.audience_members_filter_params,
        with_ids: true,
        ids: [member.id]
      ).sole
      expect(current_match.purchase_id).to eq(later_purchase.id)

      expect do
        described_class.new.perform(
          installment.id,
          stale_version,
          purchase.id,
          nil,
          nil,
          nil,
          reference_time.iso8601
        )
      end.to change(SendWorkflowInstallmentRescheduleJob.jobs, :size).by(1)

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

  describe "member_cancellation_installment" do
    before do
      @creator = create(:user)
      @product = create(:subscription_product, user: @creator)
      @subscription = create(:subscription, link: @product, cancelled_by_buyer: true, cancelled_at: 2.days.ago, deactivated_at: 1.day.ago)
      @workflow = create(:workflow, seller: @creator, link: @product, workflow_trigger: "member_cancellation")
      @installment = create(:published_installment, link: @product, workflow: @workflow, workflow_trigger: "member_cancellation")
      @installment_rule = create(:installment_rule, installment: @installment, delayed_delivery_time: 1.day)
      @sale = create(:free_purchase, is_original_subscription_purchase: true, link: @product, subscription: @subscription, email: "test@gmail.com", created_at: 1.week.ago)
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
      expect(PostSendgridApi).not_to receive(:process)

      expect do
        SendWorkflowInstallmentWorker.new.perform(
          @installment.id,
          stale_version,
          nil,
          nil,
          nil,
          @subscription.id,
          reference_time.iso8601
        )
      end.to change(SendWorkflowInstallmentRescheduleJob.jobs, :size).by(1)

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

  describe "affiliate installment reschedules" do
    before do
      @seller = create(:user)
      @product = create(:product, user: @seller)
      workflow = create(:affiliate_workflow, seller: @seller, link: @product)
      @installment = create(
        :affiliate_installment,
        seller: @seller,
        workflow:,
        published_at: Time.current,
        affiliate_products: [@product.unique_permalink]
      )
      @rule = create(:installment_rule, installment: @installment, delayed_delivery_time: 1.day)
      @affiliate = create(:direct_affiliate, seller: @seller, send_posts: true)
      @affiliate.products << @product
      @stale_version = @rule.version
      @rule.update!(delayed_delivery_time: 2.days)
      expect(PostSendgridApi).not_to receive(:process)
    end

    it "does not restore an affiliate who no longer accepts posts" do
      @affiliate.update_posts_subscription(send_posts: false)

      expect do
        described_class.new.perform(
          @installment.id,
          @stale_version,
          nil,
          nil,
          @affiliate.affiliate_user_id,
          nil,
          @affiliate.created_at.iso8601
        )
      end.not_to change(SendWorkflowInstallmentRescheduleJob.jobs, :size)
    end

    it "does not attach the old job to a recreated affiliate relationship" do
      affiliate_user = @affiliate.affiliate_user
      reference_time = @affiliate.created_at.iso8601
      @affiliate.mark_deleted!
      new_affiliate = create(
        :direct_affiliate,
        seller: @seller,
        affiliate_user:,
        send_posts: true,
        created_at: 1.minute.from_now
      )
      new_affiliate.products << @product

      expect do
        described_class.new.perform(
          @installment.id,
          @stale_version,
          nil,
          nil,
          affiliate_user.id,
          nil,
          reference_time
        )
      end.not_to change(SendWorkflowInstallmentRescheduleJob.jobs, :size)
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
