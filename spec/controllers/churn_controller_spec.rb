# frozen_string_literal: true

require "spec_helper"

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
        product  # Ensure product exists
        allow(LargeSeller).to receive(:where).and_return(double(exists?: true))

        create(:creator_analytics_churn_cache,
               user: user,
               date: end_date,
               customer_churn_rate: 10.5,
               churned_subscribers: 5,
               churned_mrr_cents: 5000)
      end

      it "uses cached data when available" do
        get :data, params: { start_time: start_date.to_s, end_time: end_date.to_s }

        json = JSON.parse(response.body)
        expect(json["daily_data"].first["churned_subscribers"]).to eq(5)
      end
    end

    context "without cached data" do
      before do
        product  # Ensure product exists
        allow(LargeSeller).to receive(:where).and_return(double(exists?: false))
      end

      it "calculates data in real-time" do
        get :data, params: { start_time: start_date.to_s, end_time: end_date.to_s }

        expect(response).to have_http_status(:success)
        json = JSON.parse(response.body)
        expect(json).to have_key("metrics")
        expect(json).to have_key("daily_data")
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

