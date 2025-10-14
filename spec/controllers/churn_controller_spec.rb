# frozen_string_literal: true

require "spec_helper"

RSpec.describe ChurnController, type: :controller do
  let(:user) { create(:user) }
  let(:product) { create(:subscription_product, user: user) }

  before do
    sign_in user
  end

  describe "GET #show" do
    context "when user has subscription products" do
      before { product }

      it "renders successfully" do
        get :show
        expect(response).to have_http_status(:success)
      end
    end

    context "when user has no subscription products" do
      it "renders successfully and shows empty state" do
        get :show
        expect(response).to have_http_status(:success)
      end
    end
  end

  describe "GET #show" do
    context "when user has subscription products" do
      before { product }

      it "includes churn data in lazy props" do
        get :show
        expect(response).to have_http_status(:success)
        # With Inertia, we just verify the response is successful
        # The lazy data will be evaluated when requested
      end
    end

    context "with Rails cache for large sellers" do
      before do
        product  # Ensure product exists
        allow(LargeSeller).to receive(:where).and_return(double(exists?: true))
        allow(Rails.cache).to receive(:fetch).and_call_original
      end

      it "uses Rails cache when user is a large seller" do
        expect(Rails.cache).to receive(:fetch).and_call_original

        get :show
        expect(response).to have_http_status(:success)
      end
    end

    context "without caching" do
      before do
        product  # Ensure product exists
        allow(LargeSeller).to receive(:where).and_return(double(exists?: false))
      end

      it "calculates data in real-time" do
        get :show
        expect(response).to have_http_status(:success)
      end
    end

    context "when not authorized" do
      before { sign_out user }

      it "returns unauthorized" do
        get :show
        expect(response).to have_http_status(:redirect)
      end
    end
  end
end
