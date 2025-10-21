# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe Admin::BaseController, type: :controller, inertia: true do
  render_views
  class DummyPolicy < ApplicationPolicy
    def index_with_policy?
      false
    end
  end

  controller(Admin::BaseController) do
    def index_with_policy
      authorize :dummy

      render json: { success: true }
    end
  end

  before do
    routes.draw do
      namespace :admin do
        get :index, to: "base#index"
        get :index_with_policy, to: "base#index_with_policy"
        get :redirect_to_stripe_dashboard, to: "base#redirect_to_stripe_dashboard"
      end
    end
  end

  let(:admin_user) { create(:admin_user) }

  describe "require_admin!" do
    shared_examples_for "404 for xhr request" do
      it do
        get :index, xhr: true
        expect_404_response(response)
      end
    end

    shared_examples_for "404 for json request format" do
      it do
        get :index, format: :json
        expect_404_response(response)
      end
    end

    context "when not logged in" do
      it_behaves_like "404 for xhr request"
      it_behaves_like "404 for json request format"

      context "with html request format" do
        before do
          @request.path = "/about"
        end

        it "redirects user to login when trying to access admin with proper next param value" do
          get :index

          expect(response).to redirect_to(login_path(next: "/about"))
        end
      end
    end

    context "when logged in" do
      let(:not_admin_user) { create(:user) }

      context "with non-admin as current user" do
        before do
          sign_in not_admin_user
        end

        context "with self as current seller" do
          # current_seller = logged_in_user for user without team_memberhip
          it_behaves_like "404 for xhr request"
          it_behaves_like "404 for json request format"

          context "with html request format" do
            it "redirects to root_path and does not add next param" do
              get :index

              expect(response).to redirect_to(root_path)
            end
          end
        end

        context "with admin as current seller" do
          before do
            allow_any_instance_of(ApplicationController).to receive(:current_seller).and_return(admin_user)
          end

          it_behaves_like "404 for xhr request"
          it_behaves_like "404 for json request format"

          context "with html request format" do
            it "redirects to root_path and does not add next param" do
              get :index

              expect(response).to redirect_to(root_path)
            end
          end
        end
      end

      context "with admin as current user" do
        before do
          sign_in admin_user
        end

        context "with self as current seller" do
          # current_seller = logged_in_user for user without team_memberhip
          it "returns the desired response" do
            get :index

            expect(response).to be_successful
            expect(inertia.component).to eq "Admin/Base/Index"
            expect(inertia.props[:title]).to eq("Admin")
          end
        end

        context "with non-admin as current seller" do
          it "returns the desired response" do
            get :index

            expect(response).to be_successful
            expect(inertia.component).to eq "Admin/Base/Index"
            expect(inertia.props[:title]).to eq("Admin")
          end
        end
      end
    end
  end

  describe "user_not_authorized" do
    before do
      sign_in admin_user
    end

    context "with JSON request" do
      it "renders JSON response" do
        get :index_with_policy, format: :json

        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["error"]).to eq("You are not allowed to perform this action.")
      end
    end

    context "with JS request" do
      it "renders JSON response" do
        get :index_with_policy, xhr: true

        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["error"]).to eq("You are not allowed to perform this action.")
      end
    end

    context "with non-JSON request" do
      it "redirects" do
        get :index_with_policy

        expect(response).to redirect_to "/"
        expect(flash[:alert]).to eq("You are not allowed to perform this action.")
      end
    end
  end

  describe "GET redirect_to_stripe_dashboard" do
    before do
      sign_in admin_user
    end

    context "when the seller has a Stripe account" do
      let(:seller) { create(:user) }
      let!(:merchant_account) { create(:merchant_account, user: seller) }

      it "redirects to Stripe dashboard" do
        get :redirect_to_stripe_dashboard, params: { user_identifier: seller.email }

        expect(response).to redirect_to(
          "https://dashboard.stripe.com/test/connect/accounts/#{merchant_account.charge_processor_merchant_id}"
        )
      end
    end

    context "when the seller is not found" do
      it "redirects to admin path with error" do
        get :redirect_to_stripe_dashboard, params: { user_identifier: "nonexistent@example.com" }

        expect(response).to redirect_to(admin_path)
        expect(flash[:alert]).to eq("User not found")
      end
    end

    context "when user has no Stripe account" do
      let(:user) { create(:user) }

      it "redirects to admin path with error" do
        get :redirect_to_stripe_dashboard, params: { user_identifier: user.email }

        expect(response).to redirect_to(admin_path)
        expect(flash[:alert]).to eq("Stripe account not found")
      end
    end
  end
end
