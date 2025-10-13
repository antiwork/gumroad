# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChurnController, type: :controller do
  let(:user) { create(:user) }
  let(:product) { create(:subscription_product, user: user) }

  before do
    sign_in user
  end

  describe "GET #index" do
    context "when user has subscription products" do
      before { product }

      it "renders successfully" do
        get :index
        expect(response).to have_http_status(:success)
      end

      it "passes churn props to the view" do
        get :index
        expect(controller.instance_variable_get(:@churn_props)).to be_present
        expect(controller.instance_variable_get(:@churn_props)[:has_subscription_products]).to be true
      end
    end

    context "when user has no subscription products" do
      it "renders successfully with empty state" do
        get :index
        expect(response).to have_http_status(:success)
      end
    end

    context "when not authenticated" do
      before { sign_out user }

      it "redirects to login" do
        get :index
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe "GET #data" do
    let(:start_date) { 30.days.ago.to_date }
    let(:end_date) { Date.current }

    context "when user has subscription products" do
      before { product }

      it "returns JSON data" do
        get :data, params: { start_time: start_date.to_s, end_time: end_date.to_s }

        expect(response).to have_http_status(:success)
        expect(response.content_type).to include("application/json")
      end

      it "includes metrics in response" do
        get :data, params: { start_time: start_date.to_s, end_time: end_date.to_s }

        json = JSON.parse(response.body)
        expect(json).to have_key("metrics")
        expect(json["metrics"]).to have_key("customer_churn_rate")
      end

      it "includes daily data in response" do
        get :data, params: { start_time: start_date.to_s, end_time: end_date.to_s }

        json = JSON.parse(response.body)
        expect(json).to have_key("daily_data")
        expect(json["daily_data"]).to be_an(Array)
      end
    end

    context "with cached data" do
      before do
        allow(Feature).to receive(:active?).with(:churn_analytics_cache, user).and_return(true)

        create(:creator_analytics_churn_cache,
               user: user,
               date: end_date,
               active_subscribers_at_start: 100,
               new_subscribers: 10,
               churned_subscribers: 5)
      end

      it "uses cached data when available" do
        get :data, params: { start_time: start_date.to_s, end_time: end_date.to_s }

        json = JSON.parse(response.body)
        expect(json["metrics"]["active_subscribers_at_start"]).to eq(100)
      end
    end

    context "without cached data" do
      before do
        allow(Feature).to receive(:active?).with(:churn_analytics_cache, user).and_return(false)
      end

      it "calculates data in real-time" do
        expect_any_instance_of(CreatorAnalytics::Churn).to receive(:calculate).and_call_original

        get :data, params: { start_time: start_date.to_s, end_time: end_date.to_s }
        expect(response).to have_http_status(:success)
      end
    end

    context "when not authorized" do
      before { sign_out user }

      it "returns unauthorized" do
        get :data, params: { start_time: start_date.to_s, end_time: end_date.to_s }
        expect(response).to have_http_status(:redirect)
      end
    end
  end
end

