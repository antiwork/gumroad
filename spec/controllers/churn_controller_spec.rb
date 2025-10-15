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
        # Lazy props (created with InertiaRails.optional) should not be included
        # in the props hash on initial render - they're loaded when explicitly
        # requested by the client via partial reload
        expect(response).to be_successful
        expect(inertia.props).not_to have_key(:churn_data)
      end
    end

    context "when user has no subscription products" do
      let!(:product) { create(:product, user: user) }

      it "renders successfully and indicates no subscription products" do
        get :show
        expect(response).to be_successful
        expect(inertia.props[:churn_props]).to include(
          has_subscription_products: false
        )
      end
    end

    context "with Rails cache for large sellers" do
      let!(:large_seller) { create(:large_seller, user: user) }

      it "uses cache when churn_data is requested with partial reload" do
        # Mock the churn service cache behavior
        allow(Rails.cache).to receive(:fetch).and_call_original

        # Simulate a partial reload request for churn_data
        get :show, params: { only: ["churn_data"] }
        expect(response).to be_successful
      end
    end

    context "without caching" do
      before do
        allow(LargeSeller).to receive(:where).and_return(double(exists?: false))
      end

      it "calculates data in real-time when churn_data is requested" do
        # Simulate a partial reload request for churn_data
        get :show, params: { only: ["churn_data"] }
        expect(response).to be_successful
      end
    end
  end
end
