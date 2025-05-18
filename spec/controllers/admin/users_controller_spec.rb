# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::UsersController do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  before do
    @admin_user = create(:admin_user, has_payout_privilege: true, has_risk_privilege: true)
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
end
