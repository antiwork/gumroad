# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

RSpec.describe ChurnController, type: :controller, inertia: true do
  include ChurnTestHelpers

  let(:user) { create(:user) }

  before { sign_in user }

  describe "GET #show" do
    context "when user has subscription products" do
      let!(:product) { create(:subscription_product, user: user) }

      it "renders the Churn/Show component with correct structure" do
        get :show

        expect(response).to be_successful
        expect(inertia.component).to eq("Churn/Show")
        expect(inertia.props[:churn_props]).to match(
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

      it "creates large seller record if warranted" do
        expect(LargeSeller).to receive(:create_if_warranted).with(user)
        get :show
      end

      it "does not include churn_data on initial load" do
        get :show
        expect(inertia.props).not_to have_key(:churn_data)
      end

      context "with partial reload requesting churn_data" do
        let(:monthly_price) { create(:price, link: product, price_cents: 1000, recurrence: "monthly") }

        before do
          # Create test data for churn calculation
          create_active_subscription(product: product, price: monthly_price, created_at: "2023-11-01 12:00:00")
          create_churned_subscription(
            product: product,
            price: monthly_price,
            created_at: "2023-11-01 12:00:00",
            deactivated_at: "2023-12-15 12:00:00"
          )
        end

        it "includes churn_data in response when explicitly requested" do
          # Stub InertiaRails.optional to execute the block
          allow(InertiaRails).to receive(:optional) do |&block|
            block.call
          end

          get :show, params: { only: ["churn_data"], from: "2023-12-01", to: "2023-12-31" }

          expect(inertia.props[:churn_data]).to be_present
          expect(inertia.props[:churn_data]).to include(
            :start_date,
            :end_date,
            :metrics,
            :daily_data
          )
          expect(inertia.props[:churn_data][:metrics]).to include(
            :customer_churn_rate,
            :last_period_churn_rate,
            :churned_subscribers,
            :churned_mrr_cents
          )

          expect(inertia.props[:churn_data][:daily_data]).to be_an(Array)
          expect(inertia.props[:churn_data][:daily_data].first).to include(
            :date,
            :customer_churn_rate,
            :churned_subscribers,
            :churned_mrr_cents,
            :active_at_start,
            :new_subscribers
          )
        end
      end
    end

    context "when user has no subscription products" do
      let!(:product) { create(:product, user: user) }

      it "denies access and redirects" do
        get :show

        expect(response).to redirect_to(dashboard_path)
        expect(flash[:alert]).to eq("You are not allowed to perform this action.")
      end
    end

    context "with date parameters" do
      let!(:product) { create(:subscription_product, user: user) }
      let(:from_date) { "2024-01-01" }
      let(:to_date) { "2024-01-31" }

      it "accepts valid date range" do
        get :show, params: { from: from_date, to: to_date }

        expect(response).to be_successful
      end

      it "raises error for invalid date range when churn_data is requested" do
        allow(InertiaRails).to receive(:optional) do |&block|
          block.call
        end

        expect do
          get :show, params: { from: "2024-01-31", to: "2024-01-01", only: ["churn_data"] }
        end.to raise_error(ArgumentError, /Invalid date range/)
      end
    end

    context "with product filtering" do
      let!(:product1) { create(:subscription_product, user: user) }
      let!(:product2) { create(:subscription_product, user: user) }
      let(:monthly_price1) { create(:price, link: product1, price_cents: 1000, recurrence: "monthly") }
      let(:monthly_price2) { create(:price, link: product2, price_cents: 2000, recurrence: "monthly") }

      before do
        create_churned_subscription(
          product: product1,
          price: monthly_price1,
          created_at: "2023-11-01 12:00:00",
          deactivated_at: "2023-12-15 12:00:00"
        )
        create_churned_subscription(
          product: product2,
          price: monthly_price2,
          created_at: "2023-11-01 12:00:00",
          deactivated_at: "2023-12-15 12:00:00"
        )
      end

      it "filters data by selected products" do
        allow(InertiaRails).to receive(:optional) do |&block|
          block.call
        end

        # Request churn data for only product1
        get :show, params: {
          only: ["churn_data"],
          from: "2023-12-01",
          to: "2023-12-31",
          products: [product1.id]
        }

        expect(response).to be_successful
        expect(inertia.props[:churn_data]).to be_present

        # Should show only product1's MRR lost ($10), not product2's ($20)
        expect(inertia.props[:churn_data][:metrics][:churned_mrr_cents]).to eq(1000)
      end
    end

    context "caching behavior" do
      let!(:product) { create(:subscription_product, user: user) }
      let(:monthly_price) { create(:price, link: product, price_cents: 1000, recurrence: "monthly") }

      before do
        create_churned_subscription(
          product: product,
          price: monthly_price,
          created_at: "2023-11-01 12:00:00",
          deactivated_at: "2023-12-15 12:00:00"
        )
      end

      context "for large sellers" do
        let!(:large_seller) { create(:large_seller, user: user) }

        it "uses caching for churn data" do
          allow(InertiaRails).to receive(:optional) do |&block|
            block.call
          end

          # First request - should cache
          get :show, params: { only: ["churn_data"], from: "2023-12-01", to: "2023-12-31" }
          first_response = inertia.props[:churn_data]

          expect(response).to be_successful
          expect(first_response).to be_present

          # Second request - should use cache
          get :show, params: { only: ["churn_data"], from: "2023-12-01", to: "2023-12-31" }
          second_response = inertia.props[:churn_data]

          expect(second_response).to eq(first_response)
        end
      end

      context "for regular sellers" do
        it "calculates data in real-time without caching" do
          allow(InertiaRails).to receive(:optional) do |&block|
            block.call
          end

          get :show, params: { only: ["churn_data"], from: "2023-12-01", to: "2023-12-31" }

          expect(response).to be_successful
          expect(inertia.props[:churn_data]).to be_present
          expect(inertia.props[:churn_data][:metrics][:churned_subscribers]).to eq(1)
        end
      end
    end

    context "error handling" do
      context "with invalid date format" do
        let!(:product) { create(:subscription_product, user: user) }

        it "raises ArgumentError for malformed dates" do
          expect do
            get :show, params: { from: "invalid-date", to: "2024-01-31", only: ["churn_data"] }
          end.to raise_error(ArgumentError)
        end
      end

      context "when service validation fails" do
        let!(:product) { create(:subscription_product, user: user) }

        it "raises ArgumentError with validation message" do
          allow(InertiaRails).to receive(:optional) do |&block|
            block.call
          end

          expect do
            get :show, params: { from: "2024-12-31", to: "2024-01-01", only: ["churn_data"] }
          end.to raise_error(ArgumentError, /Invalid date range/)
        end
      end
    end
  end
end
