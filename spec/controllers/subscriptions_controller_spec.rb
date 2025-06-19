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

  # Helper method to parse JSON response bodies
  def json_response
    JSON.parse(response.body)
  end

  describe 'POST #pause' do
    let!(:subscription_to_pause) { create(:subscription, link: @product, user: subscriber, seller: seller) }

    context 'when user is not authenticated' do
      it 'returns an unauthorized status or redirects' do
        post :pause, params: { id: subscription_to_pause.external_id }, format: :json
        # Depending on Devise setup, this might be a redirect (302) or 401
        # For JSON API, 401 is more common. Let's assume it redirects to login for HTML,
        # but for JSON, it should be 401 or a similar error if not handled gracefully by a before_action.
        # Given PUBLIC_ACTIONS does not include pause, authenticate_user! will trigger.
        # By default, Devise returns 401 for unauthenticated JSON requests.
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when user is authenticated' do
      before do
        sign_in subscriber # Assumes sign_in helper from Devise::Test::ControllerHelpers or similar
      end

      context 'and authorized' do
        before do
          # Stub Pundit authorization
          allow(controller).to receive(:authorize).with(instance_of(Subscription)).and_return(true)
          # Ensure the correct subscription is found
          allow(Subscription).to receive(:find_by_external_id).with(subscription_to_pause.external_id).and_return(subscription_to_pause)
        end

        it 'calls pause! on the subscription and returns success' do
          expect(subscription_to_pause).to receive(:pause!).with(paused_by_user: true).and_call_original
          post :pause, params: { id: subscription_to_pause.external_id }, format: :json
          expect(response).to have_http_status(:ok)
          expect(json_response['success']).to be true
        end

        it 'returns an error if pausing fails (e.g., RecordInvalid)' do
          allow(subscription_to_pause).to receive(:pause!).and_raise(ActiveRecord::RecordInvalid.new(subscription_to_pause))
          post :pause, params: { id: subscription_to_pause.external_id }, format: :json
          expect(response).to have_http_status(:unprocessable_entity)
          expect(json_response['success']).to be false
          expect(json_response['error']).to be_present
        end

        it 'returns an error if pausing fails (e.g., Subscription::StateError)' do
          allow(subscription_to_pause).to receive(:pause!).and_raise(Subscription::StateError.new("Cannot pause this"))
          post :pause, params: { id: subscription_to_pause.external_id }, format: :json
          expect(response).to have_http_status(:unprocessable_entity)
          expect(json_response['success']).to be false
          expect(json_response['error']).to eq("Cannot pause this")
        end

        it 'returns an error if pausing fails (e.g., unexpected StandardError)' do
          allow(subscription_to_pause).to receive(:pause!).and_raise(StandardError.new("Something went wrong"))
          post :pause, params: { id: subscription_to_pause.external_id }, format: :json
          expect(response).to have_http_status(:internal_server_error)
          expect(json_response['success']).to be false
          expect(json_response['error']).to eq("An unexpected error occurred.")
        end
      end

      context 'and not authorized' do
        it 'returns a forbidden status or redirects' do
          # Simulate Pundit denying authorization
          allow(controller).to receive(:authorize).with(instance_of(Subscription)).and_raise(Pundit::NotAuthorizedError)
          allow(Subscription).to receive(:find_by_external_id).with(subscription_to_pause.external_id).and_return(subscription_to_pause)

          post :pause, params: { id: subscription_to_pause.external_id }, format: :json
          # Default Pundit behavior is often to raise error, which Rails turns into 403 if not rescued by app's ApplicationController
          # Or the controller itself might rescue_from Pundit::NotAuthorizedError
          # For this test, let's assume a generic error handler might lead to 403 or redirect.
          # If ApplicationController#user_not_authorized is default, it's a redirect for HTML, 403 for JSON.
          expect(response).to have_http_status(:forbidden) # Or :redirect or check specific app rescue behavior
        end
      end
    end

    context 'when subscription is not found' do
      before { sign_in subscriber }
      it 'returns a not found status or error' do
        allow(Subscription).to receive(:find_by_external_id).with("invalid-id").and_return(nil)
        post :pause, params: { id: "invalid-id" }, format: :json
        # The controller's fetch_subscription does: render json: { success: false } if @subscription.nil?
        expect(response).to have_http_status(:ok)
        expect(json_response['success']).to be false
      end
    end
  end

  describe 'POST #resume' do
    let!(:subscription_to_resume) { create(:subscription, link: @product, user: subscriber, seller: seller, paused_at: Time.current, paused: true, deactivated_at: Time.current) }

    context 'when user is not authenticated' do
      it 'returns an unauthorized status' do
        post :resume, params: { id: subscription_to_resume.external_id }, format: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when user is authenticated' do
      before do
        sign_in subscriber
      end

      context 'and authorized' do
        before do
          allow(controller).to receive(:authorize).with(instance_of(Subscription)).and_return(true)
          allow(Subscription).to receive(:find_by_external_id).with(subscription_to_resume.external_id).and_return(subscription_to_resume)
        end

        context 'when subscription is actually paused' do
          before do
            allow(subscription_to_resume).to receive(:paused?).and_return(true)
          end

          it 'calls resume! on the subscription and returns success' do
            expect(subscription_to_resume).to receive(:resume!).and_call_original
            post :resume, params: { id: subscription_to_resume.external_id }, format: :json
            expect(response).to have_http_status(:ok)
            expect(json_response['success']).to be true
          end

          it 'returns an error if resuming fails (e.g., RecordInvalid)' do
            allow(subscription_to_resume).to receive(:resume!).and_raise(ActiveRecord::RecordInvalid.new(subscription_to_resume))
            post :resume, params: { id: subscription_to_resume.external_id }, format: :json
            expect(response).to have_http_status(:unprocessable_entity)
            expect(json_response['success']).to be false
            expect(json_response['error']).to be_present
          end

          it 'returns an error if resuming fails (e.g., Subscription::StateError)' do
            allow(subscription_to_resume).to receive(:resume!).and_raise(Subscription::StateError.new("Cannot resume this"))
            post :resume, params: { id: subscription_to_resume.external_id }, format: :json
            expect(response).to have_http_status(:unprocessable_entity)
            expect(json_response['success']).to be false
            expect(json_response['error']).to eq("Cannot resume this")
          end

          it 'returns an error if resuming fails (e.g., unexpected StandardError)' do
            allow(subscription_to_resume).to receive(:resume!).and_raise(StandardError.new("Something went wrong"))
            post :resume, params: { id: subscription_to_resume.external_id }, format: :json
            expect(response).to have_http_status(:internal_server_error)
            expect(json_response['success']).to be false
            expect(json_response['error']).to eq("An unexpected error occurred.")
          end
        end

        context 'when subscription is not currently paused (controller pre-check)' do
          before do
            # Ensure find_by_external_id still returns the subscription, but it's not paused
            allow(Subscription).to receive(:find_by_external_id).with(subscription_to_resume.external_id).and_return(subscription_to_resume)
            allow(subscription_to_resume).to receive(:paused?).and_return(false)
            expect(subscription_to_resume).not_to receive(:resume!) # Model method should not be called
          end

          it 'returns an unprocessable_entity error with specific message' do
            post :resume, params: { id: subscription_to_resume.external_id }, format: :json
            expect(response).to have_http_status(:unprocessable_entity)
            expect(json_response['success']).to be false
            expect(json_response['error']).to eq("Subscription is not currently paused.")
          end
        end
      end

      context 'and not authorized' do
        it 'returns a forbidden status' do
          allow(controller).to receive(:authorize).with(instance_of(Subscription)).and_raise(Pundit::NotAuthorizedError)
          allow(Subscription).to receive(:find_by_external_id).with(subscription_to_resume.external_id).and_return(subscription_to_resume)
          post :resume, params: { id: subscription_to_resume.external_id }, format: :json
          expect(response).to have_http_status(:forbidden)
        end
      end
    end

    context 'when subscription is not found' do
      before { sign_in subscriber }
      it 'returns a not found error' do
        allow(Subscription).to receive(:find_by_external_id).with("invalid-id").and_return(nil)
        post :resume, params: { id: "invalid-id" }, format: :json
        expect(response).to have_http_status(:ok)
        expect(json_response['success']).to be false
      end
    end
  end
end
