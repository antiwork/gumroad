# frozen_string_literal: true

require "test_helper"
require "shared_examples/authorize_called"

class SubscriptionsControllerTest < ActionController::TestCase
  self.described_class = SubscriptionsController
  tests SubscriptionsController



  context_ SubscriptionsController do
    let(:seller) { create(:named_seller) }
    let(:subscriber) { create(:user) }

    before do
      @product = create(:membership_product, subscription_duration: "monthly", user: seller)
      @subscription = create(:subscription, link: @product, user: subscriber)
      @purchase = create(:purchase, link: @product, subscription: @subscription, is_original_subscription_purchase: true)
    end

  context_ "within seller area" do
      include_context "with user signed in as admin for seller"

  context_ "POST unsubscribe_by_seller" do
        it_behaves_like "authorize called for action", :post, :unsubscribe_by_seller do
          let(:record) { @subscription }
          let(:request_params) { { id: @subscription.external_id } }
        end

  test "unsubscribes the user from the seller" do
          travel_to(Time.current) do
            expect do
              post :unsubscribe_by_seller, params: { id: @subscription.external_id }
            end.to change { @subscription.reload.user_requested_cancellation_at.try(:utc).try(:to_i) }.from(nil).to(Time.current.to_i)
            expect(response).to be_successful
          end
        end

  test "sends the correct email" do
          mailer_double = double
          allow(mailer_double).to receive(:deliver_later)
          expect(CustomerLowPriorityMailer).to receive(:subscription_cancelled_by_seller).and_return(mailer_double)
          post :unsubscribe_by_seller, params: { id: @subscription.external_id }
          expect(response).to be_successful
        end
      end
    end

  context_ "within consumer area" do
  context_ "POST unsubscribe_by_user" do
        before do
          cookies.encrypted[@subscription.cookie_key] = @subscription.external_id
        end

  test "unsubscribes the user" do
          travel_to(Time.current) do
            expect { post :unsubscribe_by_user, params: { id: @subscription.external_id } }
              .to change { @subscription.reload.user_requested_cancellation_at.try(:utc).try(:to_i) }.from(nil).to(Time.current.to_i)
          end
        end

  test "sends the correct email" do
          mail_double = double
          allow(mail_double).to receive(:deliver_later)
          expect(CustomerLowPriorityMailer).to receive(:subscription_cancelled).and_return(mail_double)
          post :unsubscribe_by_user, params: { id: @subscription.external_id }
        end

  test "does not send the incorrect email" do
          expect(CustomerLowPriorityMailer).not_to receive(:subscription_cancelled_by_seller)
          post :unsubscribe_by_user, params: { id: @subscription.external_id }
        end

  test "redirects to manage page with success notice" do
          post :unsubscribe_by_user, params: { id: @subscription.external_id }
          expect(response).to redirect_to(manage_subscription_path(@subscription.external_id))
          expect(flash[:notice]).to eq("Your membership has been cancelled.")
        end

  test "is not allowed for installment plans" do
          product = create(:product, :with_installment_plan, user: seller, price_cents: 30_00)
          purchase_with_installment_plan = create(:installment_plan_purchase, link: product, purchaser: subscriber)
          subscription = purchase_with_installment_plan.subscription
          cookies.encrypted[subscription.cookie_key] = subscription.external_id

          post :unsubscribe_by_user, params: { id: subscription.external_id }

          expect(response).to redirect_to(manage_subscription_path(subscription.external_id))
          expect(flash[:alert]).to include("Installment plans cannot be cancelled by the customer")
        end

  context_ "when the encrypted cookie is not present" do
          before do
            cookies.encrypted[@subscription.cookie_key] = nil
          end

  test "redirects to magic link page" do
            expect do
              post :unsubscribe_by_user, params: { id: @subscription.external_id }
            end.not_to change { @subscription.reload.user_requested_cancellation_at }

            expect(response).to redirect_to(new_subscription_magic_link_path(@subscription.external_id))
          end
        end
      end

  context_ "GET manage" do
  context_ "when subscription has ended" do
  test "returns 404" do
            expect { get :manage, params: { id: @subscription.external_id } }.not_to raise_error

            @subscription.end_subscription!

            expect { get :manage, params: { id: @subscription.external_id } }.to raise_error(ActionController::RoutingError)
          end
        end

  context_ "when installment plan is completed" do
  test "returns 404" do
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

  context_ "when encrypted cookie is present" do
  test "renders the manage page" do
            cookies.encrypted[@subscription.cookie_key] = @subscription.external_id
            get :manage, params: { id: @subscription.external_id }

            expect(response).to be_successful
          end
        end

  context_ "when the user is signed in" do
  test "renders the manage page" do
            sign_in subscriber
            get :manage, params: { id: @subscription.external_id }

            expect(response).to be_successful
          end
        end

  context_ "when subscription is a gift" do
          let(:gifter) { create(:user) }
          let(:giftee) { create(:user) }
          let(:product) { create(:membership_product, user: seller) }
          let!(:gifted_subscription) { create(:subscription, link: product, user: giftee) }
          let!(:gifter_purchase) { create(:purchase, :gift_sender, link: product, purchaser: gifter, is_original_subscription_purchase: true, subscription: gifted_subscription) }
          let!(:giftee_purchase) { create(:purchase, :gift_receiver, link: product, purchaser: giftee, subscription: gifted_subscription) }
          let!(:gift) { create(:gift, gifter_purchase:, giftee_purchase:, link: product) }

  test "allows gifter to access manage page" do
            sign_in gifter
            get :manage, params: { id: gifted_subscription.external_id }

            expect(response).to be_successful
          end

  test "allows giftee to access manage page" do
            sign_in giftee
            get :manage, params: { id: gifted_subscription.external_id }

            expect(response).to be_successful
          end
        end

  context_ "when the token param is same as subscription's token" do
  test "renders the manage page" do
            @subscription.update!(token: "valid_token", token_expires_at: 1.day.from_now)
            get :manage, params: { id: @subscription.external_id, token: "valid_token" }

            expect(response).to be_successful
          end
        end

  context_ "when the token is provided but doesn't match with subscription's token" do
  test "redirects to the magic link page" do
            get :manage, params: { id: @subscription.external_id, token: "not_valid_token" }

            expect(response).to redirect_to(new_subscription_magic_link_path(@subscription.external_id, invalid: true))
          end
        end

  context_ "when CheckoutPresenter#subscription_manager_props returns nil" do
  test "returns 404 instead of raising NoMethodError on the inertia render" do
            cookies.encrypted[@subscription.cookie_key] = @subscription.external_id
            allow_any_instance_of(CheckoutPresenter).to receive(:subscription_manager_props).and_return(nil)

            expect { get :manage, params: { id: @subscription.external_id } }.to raise_error(ActionController::RoutingError)
          end
        end

  context_ "when the token is provided but it has expired" do
  test "redirects to the magic link page" do
            @subscription.update!(token: "valid_token", token_expires_at: 1.day.ago)
            get :manage, params: { id: @subscription.external_id, token: "valid_token" }

            expect(response).to redirect_to(new_subscription_magic_link_path(@subscription.external_id, invalid: true))
          end
        end

  context_ "when it renders manage page successfully" do
  test "sets subscription cookie" do
            @subscription.update!(token: "valid_token", token_expires_at: 1.day.from_now)

            get :manage, params: { id: @subscription.external_id, token: "valid_token" }
            expect(response.cookies[@subscription.cookie_key]).not_to be_nil
          end
        end

  test "sets X-Robots-Tag response header to avoid search engines indexing the page" do
          get :manage, params: { id: @subscription.external_id }

          expect(response.headers["X-Robots-Tag"]).to eq "noindex"
        end
      end
    end
  end
end
