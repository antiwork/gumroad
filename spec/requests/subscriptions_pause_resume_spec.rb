# frozen_string_literal: true

require 'rails_helper'

RSpec.describe "Subscriptions Pause and Resume API", type: :request do
  # Include Devise test helpers for sign_in and sign_out
  # Ensure this is configured in rails_helper.rb or spec_helper.rb:
  # config.include Devise::Test::IntegrationHelpers, type: :request
  include Devise::Test::IntegrationHelpers

  let(:seller_user) { create(:user, :seller) } # Assuming a :seller trait
  let(:buyer_user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:product_link) { create(:link, user: seller_user, price_cents: 1000, subscription_duration: :monthly) }

  # Helper to parse JSON response bodies
  def json_response
    JSON.parse(response.body)
  end

  describe "POST /subscriptions/:id/pause" do
    let!(:subscription) { create(:subscription, link: product_link, user: buyer_user, seller: seller_user, next_charge_at: Time.current + 10.days) }
    let!(:original_purchase) { create(:purchase, :is_original_subscription_purchase, subscription: subscription, link: product_link, user: buyer_user) }


    context "when authenticated as the subscription owner" do
      before do
        sign_in buyer_user
      end

      context "with an active subscription" do
        it "pauses the subscription and returns success" do
          post "/subscriptions/#{subscription.external_id}/pause", as: :json

          expect(response).to have_http_status(:ok)
          expect(json_response["success"]).to be true

          subscription.reload
          expect(subscription.paused?).to be true
          expect(subscription.paused_at).to be_present
          expect(subscription.deactivated_at).to be_present
        end
      end

      context "with an already paused subscription" do
        before do
          subscription.pause!(paused_by_user: true) # Pause it first via model method
        end
        it "returns an unprocessable_entity error" do
          post "/subscriptions/#{subscription.external_id}/pause", as: :json
          expect(response).to have_http_status(:unprocessable_entity)
          expect(json_response["success"]).to be false
          expect(json_response["error"]).to match(/Subscription cannot be paused/)
        end
      end

      context "with a cancelled subscription" do
        before do
          subscription.cancel!(by_seller: false) # Cancel it
          subscription.deactivate! if subscription.cancelled_at <= Time.current # Ensure deactivated if cancel was immediate
        end
        it "returns an unprocessable_entity error" do
          post "/subscriptions/#{subscription.external_id}/pause", as: :json
          expect(response).to have_http_status(:unprocessable_entity)
          expect(json_response["success"]).to be false
          expect(json_response["error"]).to match(/Subscription cannot be paused/)
        end
      end
    end

    context "when unauthenticated" do
      it "returns unauthorized" do
        post "/subscriptions/#{subscription.external_id}/pause", as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when authenticated as a different user (unauthorized)" do
      before do
        sign_in other_user
      end
      it "returns forbidden (or not_found depending on Pundit setup)" do
        # Pundit's default behavior for unauthorized actions in JSON is often :forbidden
        # However, `authorize @subscription` in controller might lead to rescue_from that renders 404 if record not found by policy scope
        # Let's assume a generic :forbidden for now.
        post "/subscriptions/#{subscription.external_id}/pause", as: :json
        expect(response).to have_http_status(:forbidden) # Or :not_found
      end
    end
  end

  describe "POST /subscriptions/:id/resume" do
    let!(:subscription) { create(:subscription, link: product_link, user: buyer_user, seller: seller_user, next_charge_at: Time.current + 30.days) }
    let!(:original_purchase) { create(:purchase, :is_original_subscription_purchase, subscription: subscription, link: product_link, user: buyer_user, price_cents: product_link.price_cents, succeeded_at: Time.current - 5.days ) }


    context "when authenticated as the subscription owner" do
      before do
        sign_in buyer_user
      end

      context "with a paused subscription" do
        let!(:initial_next_charge_at) { subscription.next_charge_at || (subscription.created_at + 30.days) }
        let!(:paused_at_time) { Time.current - 7.days }

        before do
          # Manually set to a known paused state for precise next_charge_at calculation
          subscription.update_columns(paused: true, paused_at: paused_at_time, deactivated_at: paused_at_time, next_charge_at: initial_next_charge_at)
        end

        it "resumes the subscription and returns success" do
          freeze_time do # Control current time for resumed_at and next_charge_at calculation
            post "/subscriptions/#{subscription.external_id}/resume", as: :json

            expect(response).to have_http_status(:ok)
            expect(json_response["success"]).to be true

            subscription.reload
            expect(subscription.paused?).to be false
            expect(subscription.resumed_at).to be_within(1.second).of(Time.current)
            expect(subscription.deactivated_at).to be_nil

            expected_paused_duration = Time.current - paused_at_time
            expect(subscription.next_charge_at).to be_within(1.second).of(initial_next_charge_at + expected_paused_duration)
          end
        end
      end

      context "with an active (not paused) subscription" do
        before do
          # Ensure subscription is active
          subscription.update_columns(paused: false, paused_at: nil, deactivated_at: nil)
        end
        it "returns an unprocessable_entity error (controller pre-check)" do
          post "/subscriptions/#{subscription.external_id}/resume", as: :json
          expect(response).to have_http_status(:unprocessable_entity)
          expect(json_response["success"]).to be false
          expect(json_response["error"]).to eq("Subscription is not currently paused.")
        end
      end

      context "with a subscription that was never paused (paused_at is nil)" do
        before do
          subscription.update_columns(paused: false, paused_at: nil, deactivated_at: nil)
        end
        it "returns an unprocessable_entity error (controller pre-check)" do
          post "/subscriptions/#{subscription.external_id}/resume", as: :json
          expect(response).to have_http_status(:unprocessable_entity)
          expect(json_response["success"]).to be false
          expect(json_response["error"]).to eq("Subscription is not currently paused.")
        end
      end

      context "attempting to resume a subscription that cannot be resumed (model raises StateError)" do
        before do
           # Setup a state that would cause resume! to raise Subscription::StateError
           # For example, if it's paused, but some other condition makes it un-resumable (hypothetical)
           # Or more simply, if it's active and `resume!` is forced past the controller check.
           # For this test, we'll assume it passed controller's `paused?` but model's `paused?` (inside `resume!`) fails.
          subscription.update_columns(paused: true, paused_at: Time.current, deactivated_at: Time.current) # It is paused
          allow_any_instance_of(Subscription).to receive(:resume!).and_raise(Subscription::StateError.new("Cannot resume in this sub-state"))
        end

        it "returns an unprocessable_entity error" do
          post "/subscriptions/#{subscription.external_id}/resume", as: :json
          expect(response).to have_http_status(:unprocessable_entity)
          expect(json_response["success"]).to be false
          expect(json_response["error"]).to eq("Cannot resume in this sub-state")
        end
      end
    end

    context "when unauthenticated" do
      it "returns unauthorized" do
        post "/subscriptions/#{subscription.external_id}/resume", as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when authenticated as a different user (unauthorized)" do
      before do
        sign_in other_user
      end
      it "returns forbidden" do
        post "/subscriptions/#{subscription.external_id}/resume", as: :json
        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end
