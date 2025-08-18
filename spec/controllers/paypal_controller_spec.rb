# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe PaypalController, :vcr do
  include AffiliateCookie

  let(:window_location) { "https://127.0.0.1:3000/l/test?wanted=true" }
  let(:paypal_auth_token) { "Bearer A21AAF5T7EesDXLWLuLRvWyMYLvqXkVxpL_exqSEColXRRl47BxzjIKhdWgw-rD2NT_hXvDyKa1bz9FBNCP24WDrd33dtD0kg" }

  before do
    allow_any_instance_of(PaypalPartnerRestCredentials).to receive(:auth_token).and_return(paypal_auth_token)
  end

  describe "#billing_agreement_token" do
    before { allow_any_instance_of(PaypalRestApi).to receive(:timestamp).and_return("1572552322") }

    context "when request passes" do
      it "returns a valid billing agreement token id" do
        post :billing_agreement_token, params: { window_location: }

        expect(response.parsed_body["billing_agreement_token_id"]).to be_a(String)
        expect(response.parsed_body["billing_agreement_token_id"]).to_not be(nil)
      end
    end
  end

  describe "#billing_agreement" do
    context "when request is invalid" do
      it "returns nil" do
        post :billing_agreement, params: { billing_agreement_token_id: "invalid_billing_agreement_token_id" }
        expect(response.body).to eq("null")
      end
    end

    context "when request is valid" do
      let(:valid_billing_agreement_token_id) { "BA-7TR16712TA5219609" }

      it "returns a valid billing agreement" do
        post :billing_agreement, params: { billing_agreement_token_id: valid_billing_agreement_token_id }

        expect(response.parsed_body["id"]).to_not be(nil)
        expect(response.parsed_body["id"]).to be_a(String)
      end
    end
  end

  describe "#connect" do
    let(:partner_referral_success_response) do
      {
        success: true,
        redirect_url: "http://dummy-paypal-url.com"
      }
    end

    let(:partner_referral_failure_response) do
      {
        success: false,
        error_message: "Invalid request. Please try again later."
      }
    end

    before do
      @user = create(:user)
      create(:user_compliance_info, user: @user)
      sign_in(@user)
      @user.mark_compliant!(author_name: "Iffy")
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(100_00)
      create(:payment_completed, user: @user)

      allow_any_instance_of(PaypalMerchantAccountManager)
        .to receive(:create_partner_referral).and_return(partner_referral_success_response)
    end

    it_behaves_like "authorize called for action", :get, :connect do
      let(:record) { @user }
      let(:policy_klass) { Settings::Payments::UserPolicy }
      let(:policy_method) { :paypal_connect? }
    end

    context "when logged in user is admin of seller account" do
      let(:admin) { create(:user) }

      before do
        create(:team_membership, user: admin, seller: @user, role: TeamMembership::ROLE_ADMIN)

        cookies.encrypted[:current_seller_id] = @user.id
        sign_in admin
      end

      it_behaves_like "authorize called for action", :get, :connect do
        let(:record) { @user }
        let(:policy_klass) { Settings::Payments::UserPolicy }
        let(:policy_method) { :paypal_connect? }
      end
    end

    it "creates paypal partner-referral for the current user" do
      expect_any_instance_of(PaypalMerchantAccountManager).to receive(:create_partner_referral).and_return(partner_referral_success_response)
      get :connect
    end

    it "returns an error alert if user is from a country where PayPal Connect is not supported" do
      create(:user_compliance_info, user: @user, country: "Egypt")

      get :connect

      expect(response).to redirect_to(settings_payments_path)
      expect(flash[:alert]).to eq("Your PayPal account could not be connected because this PayPal integration is not supported in your country.")
    end

    it "returns an error alert if user is not allowed to connect their PayPal account" do
      @user.update!(user_risk_state: "not_reviewed")

      get :connect

      expect(response).to redirect_to(settings_payments_path)
      expect(flash[:alert]).to eq("Your PayPal account could not be connected because you do not meet the eligibility requirements.")
    end

    context "when response is success" do
      it "redirects to the paypal url" do
        get :connect
        expect(response).to redirect_to(partner_referral_success_response[:redirect_url])
      end
    end

    context "when response is failure" do
      before do
        allow_any_instance_of(PaypalMerchantAccountManager)
          .to receive(:create_partner_referral).and_return(partner_referral_failure_response)
        get :connect
      end

      it "redirects to the payment settings path" do
        expect(response).to redirect_to(settings_payments_path)
      end

      it "show error in flash" do
        expect(flash[:notice]).to eq("Invalid request. Please try again later.")
      end
    end
  end

  describe "#disconnect" do
    before do
      @user = create(:user)
      sign_in(@user)
      @merchant_account = create(:merchant_account, user: @user,
                                                    charge_processor_merchant_id: "PaypalAccountID",
                                                    charge_processor_id: "paypal",
                                                    charge_processor_verified_at: Time.current,
                                                    charge_processor_alive_at: Time.current)
    end

    it_behaves_like "authorize called for action", :post, :disconnect do
      let(:record) { @user }
      let(:policy_klass) { Settings::Payments::UserPolicy }
      let(:policy_method) { :paypal_connect? }
    end

    context "when logged in user is admin of seller account" do
      let(:admin) { create(:user) }

      before do
        create(:team_membership, user: admin, seller: @user, role: TeamMembership::ROLE_ADMIN)

        cookies.encrypted[:current_seller_id] = @user.id
        sign_in admin
      end

      it_behaves_like "authorize called for action", :post, :disconnect do
        let(:record) { @user }
        let(:policy_klass) { Settings::Payments::UserPolicy }
        let(:policy_method) { :paypal_connect? }
      end
    end

    it "redirects if logged_in_user is not present" do
      sign_out(@user)

      post :disconnect

      expect(response).to redirect_to(login_url(next: request.path))
    end

    it "marks the paypal merchant account as deleted but does not clear the charge processor merchant id" do
      expect(@user.merchant_account(PaypalChargeProcessor.charge_processor_id).charge_processor_merchant_id).to eq("PaypalAccountID")

      post :disconnect

      expect(@user.merchant_account(PaypalChargeProcessor.charge_processor_id)).to be(nil)
      expect(@merchant_account.reload.charge_processor_merchant_id).to eq("PaypalAccountID")
    end

    it "allows disconnecting a paypal merchant account that is not charge_processor_alive" do
      @merchant_account.charge_processor_alive_at = nil
      @merchant_account.save!
      expect(@user.merchant_account(PaypalChargeProcessor.charge_processor_id)).to be(nil)
      expect(@user.merchant_accounts.alive.where(charge_processor_id: PaypalChargeProcessor.charge_processor_id).last.charge_processor_merchant_id).to eq("PaypalAccountID")

      post :disconnect

      expect(@user.merchant_account(PaypalChargeProcessor.charge_processor_id)).to be(nil)
      expect(@user.merchant_accounts.alive.where(charge_processor_id: PaypalChargeProcessor.charge_processor_id).count).to eq(0)
      expect(@merchant_account.reload.charge_processor_merchant_id).to eq("PaypalAccountID")
    end

    it "does nothing and redirects to payments settings page if paypal disconnect is not allowed" do
      allow_any_instance_of(User).to receive(:paypal_disconnect_allowed?).and_return(false)

      post :disconnect
      expect(@user.merchant_account(PaypalChargeProcessor.charge_processor_id).charge_processor_merchant_id).to eq("PaypalAccountID")
      expect(response).to redirect_to(settings_payments_url)
      expect(flash[:notice]).to eq("You cannot disconnect your PayPal account because it is being used for active subscription or preorder payments.")
    end
  end

  describe "#order" do
    before { allow_any_instance_of(PaypalRestApi).to receive(:timestamp).and_return("1572552322") }

    let(:product) { create(:product, :recommendable) }

    let(:product_info) do
      {
        external_id: product.external_id,
        currency_code: "usd",
        price_cents: "1500",
        shipping_cents: "150",
        tax_cents: "100",
        exclusive_tax_cents: "100",
        total_cents: "1750",
        quantity: 3
      }
    end
    let!(:merchant_account) { create(:merchant_account_paypal, user: product.user, charge_processor_merchant_id: "CJS32DZ7NDN5L") }

    before do
      expect(PaypalChargeProcessor).to receive(:create_order_from_product_info).and_call_original
    end

    it "creates new paypal order" do
      post :order, params: { product: product_info }

      expect(response.parsed_body["order_id"]).to be_present
    end

    context "for affiliate sales" do
      let(:purchase_info) do
        {
          amount_cents: product_info[:price_cents].to_i,
          vat_cents: 0,
          affiliate_id: nil,
          was_recommended: false,
        }
      end

      context "by a direct affiliate" do
        let(:affiliate) { create(:direct_affiliate, seller: product.user, products: [product]) }

        before do
          create_affiliate_id_cookie(affiliate)
        end

        it "credits the affiliate" do
          expect_any_instance_of(Link).to receive(:gumroad_amount_for_paypal_order).with(purchase_info.merge(affiliate_id: affiliate.id))

          post :order, params: { product: product_info }
        end

        it "does not credit the affiliate for a Discover purchase" do
          expect_any_instance_of(Link).to receive(:gumroad_amount_for_paypal_order).with(purchase_info.merge(was_recommended: true))

          post :order, params: { product: product_info.merge(was_recommended: "true") }
        end
      end

      context "by a global affiliate" do
        let(:affiliate) { create(:user).global_affiliate }

        before do
          create_affiliate_id_cookie(affiliate)
        end

        it "credits the affiliate" do
          expect_any_instance_of(Link).to receive(:gumroad_amount_for_paypal_order).with(purchase_info.merge(affiliate_id: affiliate.id))

          post :order, params: { product: product_info }
        end

        it "credits the affiliate even for a Discover purchase" do
          expect_any_instance_of(Link).to receive(:gumroad_amount_for_paypal_order).with(purchase_info.merge(affiliate_id: affiliate.id, was_recommended: true))

          post :order, params: { product: product_info.merge(was_recommended: "true") }
        end
      end
    end
  end

  describe "#fetch_order" do
    context "when request is invalid" do
      it "returns nil" do
        get :fetch_order, params: { order_id: "invalid_order" }
        expect(response.body).to eq({}.to_json)
      end
    end

    context "when request is valid" do
      it "returns the paypal order details" do
        get :fetch_order, params: { order_id: "9J862133JL8076730" }

        order_id = response.parsed_body["id"]
        expect(order_id).to eq("9J862133JL8076730")
      end
    end
  end

  describe "update_order" do
    before { allow_any_instance_of(PaypalRestApi).to receive(:timestamp).and_return("1572552322") }

    let(:product) { create(:product, :recommendable) }

    let(:product_info) do
      {
        external_id: product.external_id,
        currency_code: "usd",
        price_cents: "1500",
        shipping_cents: "150",
        tax_cents: "100",
        exclusive_tax_cents: "100",
        total_cents: "1750",
        quantity: 3
      }
    end

    let(:updated_product_info) do
      {
        external_id: product.external_id,
        currency_code: "usd",
        price_cents: "750",
        shipping_cents: "75",
        tax_cents: "50",
        exclusive_tax_cents: "50",
        total_cents: "875",
        quantity: 3
      }
    end

    let!(:merchant_account) { create(:merchant_account_paypal, user: product.user, charge_processor_merchant_id: "CJS32DZ7NDN5L") }

    before do
      expect(PaypalChargeProcessor).to receive(:update_order_from_product_info).and_call_original
    end

    it "updates the paypal order with the given info and returns true" do
      paypal_order_id = PaypalChargeProcessor.create_order_from_product_info(product_info)

      post :update_order, params: { order_id: paypal_order_id, product: updated_product_info }

      expect(response.parsed_body["success"]).to be(true)
    end

    it "returns false if updating the paypal order with the given info fails" do
      expect(PaypalChargeProcessor).to receive(:update_order).and_raise(ChargeProcessorError)

      paypal_order_id = PaypalChargeProcessor.create_order_from_product_info(product_info)

      post :update_order, params: { order_id: paypal_order_id, product: updated_product_info }

      expect(response.parsed_body["success"]).to be(false)
    end
  end
end
