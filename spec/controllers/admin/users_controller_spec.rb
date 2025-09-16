# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::UsersController do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  before do
    @admin_user = create(:admin_user)
    sign_in @admin_user
  end

  describe "GET 'verify'" do
    before do
      @user = create(:user)
      @product = create(:product, user: @user)
      @purchases = []
      5.times do
        @purchases << create(:purchase, link: @product, seller: @product.user, stripe_transaction_id: rand(9_999))
      end
      @params = { id: @user.id }
    end

    it "successfully verifies and unverifies users" do
      expect(@user.verified.nil?).to be(true)
      get :verify, params: @params
      expect(response.parsed_body["success"]).to be(true)
      expect(@user.reload.verified).to be(true)

      get :verify, params: @params
      expect(response.parsed_body["success"]).to be(true)
      expect(@user.reload.verified).to be(false)
    end

    context "when error is raised" do
      before do
        allow_any_instance_of(User).to receive(:save!).and_raise("Error!")
      end

      it "rescues and returns error message" do
        get :verify, params: @params

        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to eq("Error!")
      end
    end
  end

  describe "GET 'show'" do
    let(:user) { create(:user) }

    it "returns page successfully" do
      get "show", params: { id: user.id }
      expect(response.body).to have_text(user.name)
    end

    it "returns page successfully when using email" do
      get "show", params: { id: user.email }
      expect(response.body).to have_text(user.name)
    end

    it "handles user with 1 product" do
      product = create(:product, user:)

      get :show, params: { id: user.id }

      expect(response.body).to have_text(product.name)
      expect(response.body).not_to have_selector("[aria-label='Pagination']")
    end

    it "handles user with more than PRODUCTS_PER_PAGE" do
      products = []
      # result is ordered by created_at desc
      created_at = Time.zone.now
      20.times do |i|
        products << create(:product, user:, name: ("a".."z").to_a[i] * 10, created_at:)
        created_at -= 1
      end

      get :show, params: { page: 1, id: user.id }

      products.first(10).each do |product|
        expect(response.body).to have_text(product.name)
      end
      products.last(10).each do |product|
        expect(response.body).not_to have_text(product.name)
      end
      expect(response.body).to have_selector("[aria-label='Pagination']")

      get :show, params: { page: 2, id: user.id }

      products.first(10).each do |product|
        expect(response.body).not_to have_text(product.name)
      end
      products.last(10).each do |product|
        expect(response.body).to have_text(product.name)
      end
      expect(response.body).to have_selector("[aria-label='Pagination']")
    end

    describe "blocked email tooltip" do
      let(:email) { "john@example.com" }
      let!(:email_blocked_object) { BlockedObject.block!(:email, email, user) }
      let!(:email_domain_blocked_object) { BlockedObject.block!(:email_domain, Mail::Address.new(email).domain, user) }

      before do
        user.update!(email:)
      end

      it "renders the tooltip" do
        get "show", params: { id: user.id }
        expect(response.body).to have_text("Email blocked")
        expect(response.body).to have_text("example.com blocked")
      end
    end
  end

  describe "refund balance logic", :vcr, :sidekiq_inline do
    describe "POST 'refund_balance'" do
      before do
        @admin_user = create(:admin_user)
        sign_in @admin_user
        @user = create(:user)
        product = create(:product, user: @user)
        @purchase = create(:purchase, link: product, purchase_state: "in_progress", chargeable: create(:chargeable))
        @purchase.process!
        @purchase.increment_sellers_balance!
        @purchase.mark_successful!
      end

      it "refunds user's purchases if the user is suspended" do
        @user.flag_for_fraud(author_id: @admin_user.id)
        @user.suspend_for_fraud(author_id: @admin_user.id)
        post :refund_balance, params: { id: @user.id }
        expect(@purchase.reload.stripe_refunded).to be(true)
      end

      it "does not refund user's purchases if the user is not suspended" do
        post :refund_balance, params: { id: @user.id }
        expect(@purchase.reload.stripe_refunded).to_not be(true)
      end
    end
  end

  describe "POST 'add_credit'" do
    before do
      @user = create(:user)
      @params = { id: @user.id,
                  credit: {
                    credit_amount: "100"
                  } }
    end

    it "successfully creates a credit" do
      expect { post :add_credit, params: @params }.to change { Credit.count }.from(0).to(1)
      expect(Credit.last.amount_cents).to eq(10_000)
      expect(Credit.last.user).to eq(@user)
    end

    it "creates a credit always associated with a gumroad merchant account" do
      create(:merchant_account, user: @user)
      @user.reload
      post :add_credit, params: @params
      expect(Credit.last.merchant_account).to eq(MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id))
      expect(Credit.last.balance.merchant_account).to eq(MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id))
    end

    it "successfully creates credits even with smaller amounts" do
      @params = { id: @user.id,
                  credit: {
                    credit_amount: ".04"
                  } }
      expect { post :add_credit, params: @params }.to change { Credit.count }.from(0).to(1)
      expect(Credit.last.amount_cents).to eq(4)
      expect(Credit.last.user).to eq(@user)
    end

    it "sends notification to user" do
      @params = { id: @user.id,
                  credit: {
                    credit_amount: ".04"
                  } }
      mail_double = double
      allow(mail_double).to receive(:deliver_later)
      expect(ContactingCreatorMailer).to receive(:credit_notification).with(@user.id, 4).and_return(mail_double)
      post :add_credit, params: @params
    end
  end

  describe "POST #mark_compliant" do
    let(:user) { create(:user) }

    it "marks the user as compliant" do
      post :mark_compliant, params: { id: user.id }
      expect(response).to be_successful
      expect(user.reload.user_risk_state).to eq "compliant"
    end

    it "creates a comment when marking compliant" do
      freeze_time do
        expect do
          post :mark_compliant, params: { id: user.id }
        end.to change(user.comments, :count).by(1)

        comment = user.comments.last
        expect(comment).to have_attributes(
          comment_type: Comment::COMMENT_TYPE_COMPLIANT,
          content: "Marked compliant by #{@admin_user.username} on #{Time.current.strftime('%B %-d, %Y')}",
          author: @admin_user
        )
      end
    end
  end

  describe "POST #set_custom_fee" do
    let(:user) { create(:user) }

    it "sets the custom fee for the user" do
      post :set_custom_fee, params: { id: user.id, custom_fee_percent: "2.5" }

      expect(response).to be_successful
      expect(user.reload.custom_fee_per_thousand).to eq 25
    end

    it "returns error if custom fee parameter is invalid" do
      post :set_custom_fee, params: { id: user.id, custom_fee_percent: "-5" }
      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["message"]).to eq("Validation failed: Custom fee per thousand must be greater than or equal to 0")
      expect(user.reload.custom_fee_per_thousand).to be_nil

      post :set_custom_fee, params: { id: user.id, custom_fee_percent: "101" }
      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["message"]).to eq("Validation failed: Custom fee per thousand must be less than or equal to 1000")
      expect(user.reload.custom_fee_per_thousand).to be_nil
    end

    it "updates the existing custom fee" do
      user.update!(custom_fee_per_thousand: 75)
      expect(user.reload.custom_fee_per_thousand).to eq 75

      post :set_custom_fee, params: { id: user.id, custom_fee_percent: "5" }

      expect(response).to be_successful
      expect(user.reload.custom_fee_per_thousand).to eq 50
    end
  end

  describe "POST #toggle_adult_products" do
    let(:user) { create(:user) }

    context "when all_adult_products is false" do
      before do
        user.update!(all_adult_products: false)
      end

      it "toggles all_adult_products to true" do
        post :toggle_adult_products, params: { id: user.id }

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(true)
        expect(user.reload.all_adult_products).to be(true)
      end
    end

    context "when all_adult_products is true" do
      before do
        user.update!(all_adult_products: true)
      end

      it "toggles all_adult_products to false" do
        post :toggle_adult_products, params: { id: user.id }

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(true)
        expect(user.reload.all_adult_products).to be(false)
      end
    end

    context "when all_adult_products is nil" do
      before do
        user.update!(all_adult_products: nil)
      end

      it "toggles all_adult_products to true" do
        post :toggle_adult_products, params: { id: user.id }

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(true)
        expect(user.reload.all_adult_products).to be(true)
      end
    end

    context "when user is found by email" do
      it "toggles all_adult_products successfully" do
        user.update!(all_adult_products: false)

        post :toggle_adult_products, params: { id: user.email }

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(true)
        expect(user.reload.all_adult_products).to be(true)
      end
    end

    context "when user is found by username" do
      it "toggles all_adult_products successfully" do
        user.update!(all_adult_products: false, username: "testuser")

        post :toggle_adult_products, params: { id: user.username }

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(true)
        expect(user.reload.all_adult_products).to be(true)
      end
    end
  end
end
