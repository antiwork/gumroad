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
end
