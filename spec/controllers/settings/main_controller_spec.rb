# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Settings::MainController do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }

  before do
    sign_in seller
  end

  it_behaves_like "authorize called for controller", Settings::Main::UserPolicy do
    let(:record) { seller }
  end

  describe "GET show" do
    include_context "with user signed in as admin for seller"

    let(:pundit_user) { SellerContext.new(user: user_with_role_for_seller, seller:) }

    it "returns http success and assigns correct instance variables" do
      get :show

      expect(response).to be_successful
      expect(assigns[:react_component_props]).to eq(SettingsPresenter.new(pundit_user:).main_props)
    end
  end

  describe "PUT update" do
    let (:user_params) do
      { seller_refund_policy: { max_refund_period_in_days: "30", fine_print: nil } }
    end

    it "submits the form successfully" do
      put :update, params: { user: user_params.merge(email: "hello@example.com") }, format: :json
      expect(response.parsed_body["success"]).to be(true)
      expect(seller.reload.unconfirmed_email).to eq("hello@example.com")
    end

    it "returns error message when StandardError is raised" do
      allow_any_instance_of(User).to receive(:update!).and_raise(StandardError)
      put :update, params: { user: user_params.merge(email: "hello@example.com") }, format: :json
      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["error_message"]).to eq("Something broke. We're looking into what happened. Sorry about this!")
    end

    describe "expires products" do
      let(:product) { create(:product, user: seller) }

      before do
        product.user.update!(enable_recurring_subscription_charge_email: true)
        Rails.cache.write(product.scoped_cache_key("en"), "<html>Hello</html>")
        product.product_cached_values.create!
      end

      it "expires the user's products", :sidekiq_inline do
        put :update, params: { user: user_params.merge(enable_recurring_subscription_charge_email: false) }, format: :json
        expect(response.parsed_body["success"]).to be(true)
        expect(Rails.cache.read(product.scoped_cache_key("en"))).to be(nil)
        expect(product.reload.product_cached_values.fresh).to eq([])
      end
    end

    it "sets error message and render show on invalid record" do
      put :update, params: { user: user_params.merge(email: "BAD EMAIL") }, format: :json
      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["error_message"]).to eq "Email is invalid"
    end

    describe "email changing" do
      describe "email is changed to something new" do
        before do
          seller.update_columns(email: "test@gumroad.com", unconfirmed_email: "test@gumroad.com")
        end

        it "sets unconfirmed_email column" do
          expect { put :update, params: { user: user_params.merge(email: "new@gumroad.com") }, format: :json }.to change {
            seller.reload.unconfirmed_email
          }.from("test@gumroad.com").to("new@gumroad.com")
        end

        it "does not change email column" do
          expect do
            put :update, params: { user: user_params.merge(email: "new@gumroad.com") }, format: :json
          end.to_not change { seller.reload.email }.from("test@gumroad.com")
        end

        it "sends email_changed notification" do
          expect do
            put :update, params: { user: user_params.merge(email: "another+email@example.com") }, format: :json
          end.to have_enqueued_mail(UserSignupMailer, :email_changed)
        end
      end

      describe "email is changed back to a confirmed email" do
        before(:each) do
          seller.update_columns(email: "test@gumroad.com", unconfirmed_email: "new@gumroad.com")
        end

        it "changes the unconfirmed_email to nil" do
          expect do
            put :update, params: { user: user_params.merge(email: "test@gumroad.com") }, format: :json
          end.to change {
            seller.reload.unconfirmed_email
          }.from("new@gumroad.com").to(nil)
        end

        it "doesn't send email_changed notification" do
          expect do
            put :update, params: { user: user_params.merge(email: seller.email) }, format: :json
          end.not_to have_enqueued_mail(UserSignupMailer, :email_changed)
        end
      end
    end

    it "updates the enable_free_downloads_email flag correctly" do
      seller.update!(enable_free_downloads_email: true)

      expect do
        put :update, params: { user: user_params.merge(enable_free_downloads_email: false) }, format: :json
        expect(response).to be_successful
      end.to change {
        seller.reload.enable_free_downloads_email
      }.from(true).to(false)

      expect do
        put :update, params: { user: user_params.merge(enable_free_downloads_email: true) }, format: :json
        expect(response).to be_successful
      end.to change {
        seller.reload.enable_free_downloads_email
      }.from(false).to(true)
    end

    it "updates the enable_free_downloads_push_notification flag correctly" do
      seller.update!(enable_free_downloads_push_notification: true)

      expect do
        put :update, params: { user: user_params.merge(enable_free_downloads_push_notification: false) }, format: :json
        expect(response).to be_successful
      end.to change {
        seller.reload.enable_free_downloads_push_notification
      }.from(true).to(false)

      expect do
        put :update, params: { user: user_params.merge(enable_free_downloads_push_notification: true) }, format: :json
        expect(response).to be_successful
      end.to change {
        seller.reload.enable_free_downloads_push_notification
      }.from(false).to(true)
    end

    it "updates the enable_recurring_subscription_charge_email flag correctly" do
      seller.update!(enable_recurring_subscription_charge_email: true)

      expect do
        put :update, params: { user: user_params.merge(enable_recurring_subscription_charge_email: false) }, format: :json
        expect(response).to be_successful
      end.to change {
        seller.reload.enable_recurring_subscription_charge_email
      }.from(true).to(false)

      expect do
        put :update, params: { user: user_params.merge(enable_recurring_subscription_charge_email: true) }, format: :json
        expect(response).to be_successful
      end.to change {
        seller.reload.enable_recurring_subscription_charge_email
      }.from(false).to(true)
    end

    it "updates the enable_recurring_subscription_charge_push_notification flag correctly" do
      seller.update!(enable_recurring_subscription_charge_push_notification: true)

      expect do
        put :update, params: { user: user_params.merge(enable_recurring_subscription_charge_push_notification: false) }, format: :json
        expect(response).to be_successful
      end.to change {
        seller.reload.enable_recurring_subscription_charge_push_notification
      }.from(true).to(false)

      expect do
        put :update, params: { user: user_params.merge(enable_recurring_subscription_charge_push_notification: true) }, format: :json
        expect(response).to be_successful
      end.to change {
        seller.reload.enable_recurring_subscription_charge_push_notification
      }.from(false).to(true)
    end

    it "updates the enable_payment_push_notification flag correctly" do
      seller.update!(enable_payment_push_notification: true)

      expect do
        put :update, params: { user: user_params.merge(enable_payment_push_notification: false) }, format: :json
        expect(response).to be_successful
      end.to change {
        seller.reload.enable_payment_push_notification
      }.from(true).to(false)

      expect do
        put :update, params: { user: user_params.merge(enable_payment_push_notification: true) }, format: :json
        expect(response).to be_successful
      end.to change {
        seller.reload.enable_payment_push_notification
      }.from(false).to(true)
    end

    it "updates the disable_comments_email flag correctly" do
      seller.update!(disable_comments_email: true)

      expect do
        put :update, params: { user: user_params.merge(disable_comments_email: false) }, format: :json
        expect(response).to be_successful
      end.to change {
        seller.reload.disable_comments_email
      }.from(true).to(false)

      expect do
        put :update, params: { user: user_params.merge(disable_comments_email: true) }, format: :json
        expect(response).to be_successful
      end.to change {
        seller.reload.disable_comments_email
      }.from(false).to(true)
    end

    it "updates the disable_reviews_email flag correctly" do
      expect do
        put :update, params: { user: user_params.merge(disable_reviews_email: true) }, format: :json
        expect(response).to be_successful
      end.to change {
        seller.reload.disable_reviews_email
      }.from(false).to(true)

      expect do
        put :update, params: { user: user_params.merge(disable_reviews_email: false) }, format: :json
        expect(response).to be_successful
      end.to change {
        seller.reload.disable_reviews_email
      }.from(true).to(false)
    end

    it "updates the show_nsfw_products flag correctly" do
      expect do
        put :update, params: { user: user_params.merge(show_nsfw_products: true) }, format: :json
        expect(response).to be_successful
      end.to change {
        seller.reload.show_nsfw_products
      }.from(false).to(true)

      expect do
        put :update, params: { user: user_params.merge(show_nsfw_products: false) }, format: :json
        expect(response).to be_successful
      end.to change {
        seller.reload.show_nsfw_products
      }.from(true).to(false)
    end

    describe "seller refund policy" do
      context "when enabled" do
        before do
          seller.refund_policy.update!(max_refund_period_in_days: 0)
        end

        it "updates the seller refund policy fine print" do
          put :update, params: { user: { seller_refund_policy: { max_refund_period_in_days: "30", fine_print: "This is a fine print" } } }, as: :json
          expect(response).to be_successful

          expect(seller.refund_policy.reload.max_refund_period_in_days).to eq(30)
          expect(seller.refund_policy.fine_print).to eq("This is a fine print")
        end

        context "when seller_refund_policy_disabled_for_all feature flag is set to true" do
          before do
            Feature.activate(:seller_refund_policy_disabled_for_all)
          end

          it "does not update the seller refund policy" do
            put :update, params: { user: { seller_refund_policy: { max_refund_period_in_days: "30", fine_print: "This is a fine print" } } }, as: :json
            expect(response).to be_successful

            expect(seller.refund_policy.reload.max_refund_period_in_days).to eq(0)
          end
        end
      end

      context "when not enabled" do
        before do
          seller.update!(refund_policy_enabled: false)
          seller.refund_policy.update!(max_refund_period_in_days: 0)
        end

        it "does not update the seller refund policy" do
          put :update, params: { user: { seller_refund_policy: { max_refund_period_in_days: "30", fine_print: "This is a fine print" } } }, as: :json
          expect(response).to be_successful

          expect(seller.refund_policy.reload.max_refund_period_in_days).to eq(0)
          expect(seller.refund_policy.fine_print).to be_nil
        end
      end

      context "product level support emails" do
        let(:product1) { create(:product, user: seller) }
        let(:product2) { create(:product, user: seller) }
        let(:other_seller) { create(:user) }
        let(:other_product) { create(:product, user: other_seller) }

        before do
          Feature.activate(:product_level_support_emails)
        end

        it "creates new support emails with associated products" do
          product_level_support_emails = [
            {
              email: "contact@example.com",
              product_ids: [product1.external_id, product2.external_id]
            },
            {
              email: "support@example.com",
              product_ids: []
            }
          ]

          put :update, params: { user: user_params.merge(product_level_support_emails:) }, format: :json

          expect(response.parsed_body["success"]).to be(true)
          expect(product1.reload.support_email).to eq("contact@example.com")
          expect(product2.reload.support_email).to eq("contact@example.com")
        end

        it "fails when email isn't valid" do
          product_level_support_emails = [
            { email: "invalid-email", product_ids: [product1.external_id] }
          ]
          put :update, params: { user: user_params.merge(product_level_support_emails:) }, format: :json

          expect(response.parsed_body["success"]).to be(false)
          expect(response.parsed_body["error_message"])
            .to eq("Something broke. We're looking into what happened. Sorry about this!")
        end

        it "only associates products belonging to current seller" do
          product_level_support_emails = [
            {
              email: "contact@example.com",
              product_ids: [product1.external_id, other_product.external_id]
            }
          ]

          put :update, params: { user: user_params.merge(product_level_support_emails:) }, format: :json

          expect(response.parsed_body["success"]).to be(true)
          expect(product1.reload.support_email).to eq("contact@example.com")
          expect(other_product.reload.support_email).to be_nil
        end

        it "clears all existing support emails if param is empty" do
          product1.update!(support_email: "support@example.com")
          product2.update!(support_email: "support@example.com")

          put :update, params: { user: user_params.merge(product_level_support_emails: []) }, format: :json

          expect(response.parsed_body["success"]).to be(true)
          expect(product1.reload.support_email).to be_nil
          expect(product2.reload.support_email).to be_nil
        end

        context "when product_level_support_emails feature is disabled" do
          before do
            Feature.deactivate(:product_level_support_emails)
          end

          it "does not update product support emails" do
            product_level_support_emails = [
              { email: "contact@example.com", product_ids: [product1.external_id] }
            ]

            put :update, params: { user: user_params.merge(product_level_support_emails:) }, format: :json

            expect(response.parsed_body["success"]).to be(true)
            expect(product1.reload.support_email).to be_nil
          end
        end
      end
    end
  end

  describe "POST resend_confirmation_email" do
    shared_examples_for "resends email confirmation" do
      it "resends email confirmation" do
        expect { post :resend_confirmation_email }
          .to have_enqueued_mail(UserSignupMailer, :confirmation_instructions)

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(true)
      end
    end

    shared_examples_for "doesn't resend email confirmation" do
      it "doesn't resend email confirmation" do
        expect { post :resend_confirmation_email }
          .not_to have_enqueued_mail(UserSignupMailer)

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(false)
      end
    end

    context "when user has email and not confirmed" do
      before do
        seller.update_columns(confirmed_at: nil)
      end

      it_behaves_like "resends email confirmation"
    end

    context "when user has changed email after confirmation" do
      before do
        seller.confirm
        seller.update_attribute(:email, "some@gumroad.com")
      end

      it_behaves_like "resends email confirmation"
    end

    context "when user is confirmed" do
      before do
        seller.confirm
      end

      it_behaves_like "doesn't resend email confirmation"
    end

    context "when user doesn't have email" do
      before do
        seller.update_columns(email: nil)
      end

      it_behaves_like "doesn't resend email confirmation"
    end
  end
end
