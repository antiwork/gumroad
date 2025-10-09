# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe SubscriptionsController do
  let(:seller) { create(:named_seller) }
  let(:subscriber) { create(:user) }

  before do
    @product = create(:membership_product, subscription_duration: "monthly", user: seller)
    @subscription = create(:subscription, link: @product, user: subscriber)
    @purchase = create(:purchase, link: @product, subscription: @subscription, is_original_subscription_purchase: true)
  end

  context "within seller area" do
    include_context "with user signed in as admin for seller"

    describe "POST unsubscribe_by_seller" do
      it_behaves_like "authorize called for action", :post, :unsubscribe_by_seller do
        let(:record) { @subscription }
        let(:request_params) { { id: @subscription.external_id } }
      end

      it "unsubscribes the user from the seller" do
        travel_to(Time.current) do
          expect do
            post :unsubscribe_by_seller, params: { id: @subscription.external_id }
          end.to change { @subscription.reload.user_requested_cancellation_at.try(:utc).try(:to_i) }.from(nil).to(Time.current.to_i)
          expect(response).to be_successful
        end
      end

      it "sends the correct email" do
        mailer_double = double
        allow(mailer_double).to receive(:deliver_later)
        expect(CustomerLowPriorityMailer).to receive(:subscription_cancelled_by_seller).and_return(mailer_double)
        post :unsubscribe_by_seller, params: { id: @subscription.external_id }
        expect(response).to be_successful
      end
    end
  end

  context "within consumer area" do
    describe "POST unsubscribe_by_user" do
      before do
        cookies.encrypted[@subscription.cookie_key] = @subscription.external_id
      end

      it "unsubscribes the user" do
        travel_to(Time.current) do
          expect { post :unsubscribe_by_user, params: { id: @subscription.external_id } }
            .to change { @subscription.reload.user_requested_cancellation_at.try(:utc).try(:to_i) }.from(nil).to(Time.current.to_i)
        end
      end

      it "sends the correct email" do
        mail_double = double
        allow(mail_double).to receive(:deliver_later)
        expect(CustomerLowPriorityMailer).to receive(:subscription_cancelled).and_return(mail_double)
        post :unsubscribe_by_user, params: { id: @subscription.external_id }
      end

      it "does not send the incorrect email" do
        expect(CustomerLowPriorityMailer).to_not receive(:subscription_cancelled_by_seller)
        post :unsubscribe_by_user, params: { id: @subscription.external_id }
      end

      it "returns json success" do
        post :unsubscribe_by_user, params: { id: @subscription.external_id }
        expect(response.parsed_body["success"]).to be(true)
      end

      it "is not allowed for installment plans" do
        product = create(:product, :with_installment_plan, user: seller, price_cents: 30_00)
        purchase_with_installment_plan = create(:installment_plan_purchase, link: product, purchaser: subscriber)
        subscription = purchase_with_installment_plan.subscription
        cookies.encrypted[subscription.cookie_key] = subscription.external_id

        post :unsubscribe_by_user, params: { id: subscription.external_id }

        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["error"]).to include("Installment plans cannot be cancelled by the customer")
      end

      context "when the encrypted cookie is not present" do
        before do
          cookies.encrypted[@subscription.cookie_key] = nil
        end

        it "renders success false with redirect_to URL" do
          expect do
            post :unsubscribe_by_user, params: { id: @subscription.external_id }, format: :json
          end.to_not change { @subscription.reload.user_requested_cancellation_at }

          expect(response.parsed_body["success"]).to be(false)
          expect(response.parsed_body["redirect_to"]).to eq(magic_link_subscription_path(@subscription.external_id))
        end
      end
    end

    describe "GET manage" do
      context "when subscription has ended" do
        it "returns 404" do
          expect { get :manage, params: { id: @subscription.external_id } }.not_to raise_error

          @subscription.end_subscription!

          expect { get :manage, params: { id: @subscription.external_id } }.to raise_error(ActionController::RoutingError)
        end
      end

      context "when installment plan is completed" do
        it "returns 404" do
          purchase = create(:installment_plan_purchase)
          subscription = purchase.subscription
          product = subscription.link

          subscription.update_columns(charge_occurrence_count: product.installment_plan.number_of_installments)

          (product.installment_plan.number_of_installments - 1).times do
            create(:purchase, link: product, subscription: subscription, purchaser: subscription.user)
          end

          cookies.encrypted[subscription.cookie_key] = subscription.external_id

          expect { get :manage, params: { id: subscription.external_id } }.to raise_error(ActionController::RoutingError)
        end
      end

      context "when encrypted cookie is present" do
        it "renders the manage page" do
          cookies.encrypted[@subscription.cookie_key] = @subscription.external_id
          get :manage, params: { id: @subscription.external_id }

          expect(response).to be_successful
        end
      end

      context "when the user is signed in" do
        it "renders the manage page" do
          sign_in subscriber
          get :manage, params: { id: @subscription.external_id }

          expect(response).to be_successful
        end
      end

      context "when the token param is same as subscription's token" do
        it "renders the manage page" do
          @subscription.update!(token: "valid_token", token_expires_at: 1.day.from_now)
          get :manage, params: { id: @subscription.external_id, token: "valid_token" }

          expect(response).to be_successful
        end
      end

      context "when the token is provided but doesn't match with subscription's token" do
        it "redirects to the magic link page" do
          get :manage, params: { id: @subscription.external_id, token: "not_valid_token" }

          expect(response).to redirect_to(magic_link_subscription_path(@subscription.external_id, invalid: true))
        end
      end

      context "when the token is provided but it has expired" do
        it "redirects to the magic link page" do
          @subscription.update!(token: "valid_token", token_expires_at: 1.day.ago)
          get :manage, params: { id: @subscription.external_id, token: "valid_token" }

          expect(response).to redirect_to(magic_link_subscription_path(@subscription.external_id, invalid: true))
        end
      end

      context "when it renders manage page successfully" do
        it "sets subscription cookie" do
          @subscription.update!(token: "valid_token", token_expires_at: 1.day.from_now)

          get :manage, params: { id: @subscription.external_id, token: "valid_token" }
          expect(response.cookies[@subscription.cookie_key]).to_not be_nil
        end
      end

      it "sets X-Robots-Tag response header to avoid search engines indexing the page" do
        get :manage, params: { id: @subscription.external_id }

        expect(response.headers["X-Robots-Tag"]).to eq "noindex"
      end
    end

    describe "GET magic_link" do
      it "renders the magic link page" do
        get :magic_link, params: { id: @subscription.external_id }

        expect(response).to be_successful
      end
    end

    describe "POST send_magic_link" do
      it "sets up the token in the subscription" do
        expect(@subscription.token).to be_nil
        post :send_magic_link, params: { id: @subscription.external_id, email_source: "user" }
        expect(@subscription.reload.token).to_not be_nil
      end

      it "sets the token to expire in 24 hours" do
        expect(@subscription.token_expires_at).to be_nil
        post :send_magic_link, params: { id: @subscription.external_id, email_source: "user" }
        expect(@subscription.reload.token_expires_at).to be_within(1.second).of(24.hours.from_now)
      end

      it "sends the magic link email" do
        mail_double = double
        allow(mail_double).to receive(:deliver_later)
        expect(CustomerMailer).to receive(:subscription_magic_link).and_return(mail_double)
        post :send_magic_link, params: { id: @subscription.external_id, email_source: "user" }
        expect(response).to be_successful
      end

      describe "email_source param" do
        before do
          @original_purchasing_user_email = subscriber.email
          @purchase.update!(email: "purchase@email.com")
          subscriber.update!(email: "subscriber@email.com")
        end

        context "when the email source is `user`" do
          it "sends the magic link email to the user's email" do
            mail_double = double
            allow(mail_double).to receive(:deliver_later)
            expect(CustomerMailer).to receive(:subscription_magic_link).with(@subscription.id, @original_purchasing_user_email).and_return(mail_double)
            post :send_magic_link, params: { id: @subscription.external_id, email_source: "user" }
            expect(response).to be_successful
          end
        end

        context "when the email source is `purchase`" do
          it "sends the magic link email to the email associated to the original purchase" do
            mail_double = double
            allow(mail_double).to receive(:deliver_later)
            expect(CustomerMailer).to receive(:subscription_magic_link).with(@subscription.id, "purchase@email.com").and_return(mail_double)
            post :send_magic_link, params: { id: @subscription.external_id, email_source: "purchase" }
            expect(response).to be_successful
          end
        end

        context "when the email source is `subscription`" do
          it "sends the magic link email to the email associated to the subscription" do
            mail_double = double
            allow(mail_double).to receive(:deliver_later)
            expect(CustomerMailer).to receive(:subscription_magic_link).with(@subscription.id, "subscriber@email.com").and_return(mail_double)
            post :send_magic_link, params: { id: @subscription.external_id, email_source: "subscription" }
            expect(response).to be_successful
          end
        end

        context "when the email source is not valid" do
          it "raises a 404 error" do
            expect do
              post :send_magic_link, params: { id: @subscription.external_id, email_source: "invalid source" }
            end.to raise_error(ActionController::RoutingError, "Not Found")
          end
        end
      end
    end
  end
end
