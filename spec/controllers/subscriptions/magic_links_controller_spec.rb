# frozen_string_literal: true

require "spec_helper"

describe Subscriptions::MagicLinksController do
  let(:seller) { create(:named_seller) }
  let(:subscriber) { create(:user) }

  before do
    @product = create(:membership_product, subscription_duration: "monthly", user: seller)
    @subscription = create(:subscription, link: @product, user: subscriber)
    @purchase = create(:purchase, link: @product, subscription: @subscription, is_original_subscription_purchase: true)
  end

  describe "GET new" do
    it "renders the magic link page" do
      get :new, params: { id: @subscription.external_id }

      expect(response).to be_successful
    end

    it "renders inertia component with correct props" do
      get :new, params: { id: @subscription.external_id }

      expect(response).to be_successful
      expect(response).to render_template("subscriptions/magic_links/new")
    end

    context "when subscription does not exist" do
      it "returns 404" do
        expect do
          get :new, params: { id: "nonexistent" }
        end.to raise_error(ActionController::RoutingError)
      end
    end
  end

  describe "POST create" do
    it "sets up the token in the subscription" do
      expect(@subscription.token).to be_nil
      post :create, params: { id: @subscription.external_id, email_source: "user" }
      expect(@subscription.reload.token).to_not be_nil
    end

    it "sets the token to expire in 24 hours" do
      expect(@subscription.token_expires_at).to be_nil
      post :create, params: { id: @subscription.external_id, email_source: "user" }
      expect(@subscription.reload.token_expires_at).to be_within(1.second).of(24.hours.from_now)
    end

    it "sends the magic link email" do
      mail_double = double
      allow(mail_double).to receive(:deliver_later)
      expect(CustomerMailer).to receive(:subscription_magic_link).and_return(mail_double)
      post :create, params: { id: @subscription.external_id, email_source: "user" }
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
          post :create, params: { id: @subscription.external_id, email_source: "user" }
          expect(response).to be_successful
        end
      end

      context "when the email source is `purchase`" do
        it "sends the magic link email to the email associated to the original purchase" do
          mail_double = double
          allow(mail_double).to receive(:deliver_later)
          expect(CustomerMailer).to receive(:subscription_magic_link).with(@subscription.id, "purchase@email.com").and_return(mail_double)
          post :create, params: { id: @subscription.external_id, email_source: "purchase" }
          expect(response).to be_successful
        end
      end

      context "when the email source is `subscription`" do
        it "sends the magic link email to the email associated to the subscription" do
          mail_double = double
          allow(mail_double).to receive(:deliver_later)
          expect(CustomerMailer).to receive(:subscription_magic_link).with(@subscription.id, "subscriber@email.com").and_return(mail_double)
          post :create, params: { id: @subscription.external_id, email_source: "subscription" }
          expect(response).to be_successful
        end
      end

      context "when the email source is not valid" do
        it "raises a 404 error" do
          expect do
            post :create, params: { id: @subscription.external_id, email_source: "invalid source" }
          end.to raise_error(ActionController::RoutingError, "Not Found")
        end
      end
    end

    context "when subscription does not exist" do
      it "returns 404" do
        expect do
          post :create, params: { id: "nonexistent", email_source: "user" }
        end.to raise_error(ActionController::RoutingError)
      end
    end
  end
end
