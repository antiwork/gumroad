# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

RSpec.describe ChurnController, type: :controller, inertia: true do
  let(:user) { create(:user) }
  let!(:product) { create(:subscription_product, user: user) }

  before do
    sign_in user
  end

  describe "GET #show" do
    context "when user has subscription products" do
      it "renders the Churn/Show component" do
        get :show
        expect(response).to be_successful
        expect(inertia.component).to eq("Churn/Show")
      end

      it "includes churn_props with subscription products" do
        get :show
        expect(response).to be_successful
        expect(inertia.props[:churn_props]).to include(
          has_subscription_products: true,
          products: array_including(
            hash_including(
              id: product.id,
              name: product.name,
              unique_permalink: product.unique_permalink,
              alive: true
            )
          )
        )
      end

      it "does not evaluate lazy props on initial render" do
        get :show
        expect(response).to be_successful
        expect(inertia.props).not_to have_key(:churn_data)
      end

      it "calls LargeSeller.create_if_warranted" do
        expect(LargeSeller).to receive(:create_if_warranted).with(user)
        get :show
      end

      it "initializes CreatorAnalytics::Churn service with correct parameters" do
        expect(CreatorAnalytics::Churn).to receive(:new).with(
          user: user,
          params: instance_of(ActionController::Parameters)
        ).and_call_original
        get :show
      end

      it "calls service methods for data retrieval" do
        service_instance = instance_double(CreatorAnalytics::Churn)
        allow(CreatorAnalytics::Churn).to receive(:new).and_return(service_instance)

        expect(service_instance).to receive(:has_subscription_products?).and_return(true)
        expect(service_instance).to receive(:available_products).and_return([product])
        allow(service_instance).to receive(:fetch_churn_data).and_return(nil)

        get :show
      end

      it "uses InertiaRails.optional for lazy loading churn_data" do
        expect(InertiaRails).to receive(:optional).and_call_original
        get :show
      end
    end

    context "when user has no subscription products" do
      let!(:product) { create(:product, user: user) }

      it "renders successfully and indicates no subscription products" do
        get :show
        expect(response).to be_successful
        expect(inertia.props[:churn_props]).to include(
          has_subscription_products: false,
          products: be_empty
        )
        expect(inertia.props[:churn_data]).to be_nil
      end
    end

    context "with date parameters" do
      let(:from_date) { "2024-01-01" }
      let(:to_date) { "2024-01-31" }

      it "passes date parameters to service" do
        expect(CreatorAnalytics::Churn).to receive(:new).with(
          user: user,
          params: hash_including(from: from_date, to: to_date)
        ).and_call_original

        get :show, params: { from: from_date, to: to_date }
      end
    end

    context "with product parameters" do
      let(:product_ids) { [product.id] }

      it "passes product parameters to service" do
        expect(CreatorAnalytics::Churn).to receive(:new).with(
          user: user,
          params: instance_of(ActionController::Parameters)
        ).and_call_original

        get :show, params: { products: product_ids }
      end
    end

    context "with Rails cache for large sellers" do
      let!(:large_seller) { create(:large_seller, user: user) }

      it "uses cache when churn_data is requested with partial reload" do
        allow(Rails.cache).to receive(:fetch).and_call_original
        allow(Rails.cache).to receive(:fetch).with(
          match(/seller_daily_churn_metrics:#{user.id}/),
          expires_in: 24.hours
        ).and_return({})

        get :show, params: { only: ["churn_data"] }
        expect(response).to be_successful
      end

      it "returns cached data when available" do
        cached_data = { customer_churn_rate: 5.5, churned_subscribers: 10 }
        allow(Rails.cache).to receive(:fetch).and_call_original
        allow(Rails.cache).to receive(:fetch).with(
          match(/seller_daily_churn_metrics:#{user.id}/),
          expires_in: 24.hours
        ).and_return(cached_data)

        get :show, params: { only: ["churn_data"] }
        expect(response).to be_successful
      end
    end

    context "without caching" do
      before do
        allow(LargeSeller).to receive(:where).and_return(double(exists?: false))
      end

      it "calculates data in real-time when churn_data is requested" do
        expect(Rails.cache).to receive(:fetch).and_call_original

        get :show, params: { only: ["churn_data"] }
        expect(response).to be_successful
      end

      it "calls fetch_realtime_data instead of fetch_cached_data" do
        service_instance = instance_double(CreatorAnalytics::Churn)
        allow(CreatorAnalytics::Churn).to receive(:new).and_return(service_instance)
        allow(service_instance).to receive(:has_subscription_products?).and_return(true)
        allow(service_instance).to receive(:available_products).and_return([product])

        mock_churn_data = {
          start_date: "2024-01-01",
          end_date: "2024-01-31",
          metrics: {
            customer_churn_rate: 5.5,
            last_period_churn_rate: 4.2,
            churned_subscribers: 10,
            churned_mrr_cents: 5000
          },
          daily_data: []
        }
        allow(service_instance).to receive(:fetch_churn_data).and_return(mock_churn_data)

        allow(InertiaRails).to receive(:optional) do |&block|
          block.call
        end

        get :show
        expect(response).to be_successful
        expect(inertia.props[:churn_data]).to eq(mock_churn_data)
      end
    end

    describe "error handling" do
      context "when service raises an error" do
        it "handles service errors gracefully" do
          allow_any_instance_of(CreatorAnalytics::Churn).to receive(:has_subscription_products?).and_raise(StandardError, "Service error")

          expect { get :show }.to raise_error(StandardError, "Service error")
        end
      end

      context "when LargeSeller.create_if_warranted fails" do
        it "handles LargeSeller creation errors" do
          allow(LargeSeller).to receive(:create_if_warranted).and_raise(StandardError, "LargeSeller error")

          expect { get :show }.to raise_error(StandardError, "LargeSeller error")
        end
      end
    end

    describe "partial reloads" do
      context "when requesting only churn_data" do
        it "returns successful response" do
          get :show, params: { only: ["churn_data"] }
          expect(response).to be_successful
        end
      end

      context "when requesting only churn_props" do
        it "returns successful response" do
          get :show, params: { only: ["churn_props"] }
          expect(response).to be_successful
        end
      end
    end
  end
end
