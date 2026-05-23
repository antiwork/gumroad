# frozen_string_literal: true

require "test_helper"
require "shared_examples/authorize_called"

class PunditAuthorizationTest < ActionController::TestCase
  self.described_class = PunditAuthorization



  context_ PunditAuthorization, type: :controller do
    class DummyPolicy < ApplicationPolicy
      def action?
        false
      end
    end

    # Does not inherit from ApplicationPolicy
    class PublicDummyPolicy
      def initialize(_context, _record)
      end

      def public_action?
        false
      end
    end

    controller(ApplicationController) do
      include PunditAuthorization

      before_action :authenticate_user!, only: [:action]
      after_action :verify_authorized

      def action
        authorize :dummy
        head :ok
      end

      def public_action
        authorize :public_dummy
        head :ok
      end
    end

    before do
      routes.draw do
        get :action, to: "anonymous#action"
        get :public_action, to: "anonymous#public_action"
      end
    end

    let(:seller) { create(:named_seller) }

  context_ "pundit_user" do
      include_context "with user signed in as admin for seller"

  test "sets correct values to SellerContext" do
        get :action

        seller_context = controller.pundit_user
        expect(seller_context.user).to eq(user_with_role_for_seller)
        expect(seller_context.seller).to eq(seller)
      end
    end

  context_ "user_not_authorized" do
  context_ "with action that requires authentication" do
        include_context "with user signed in as admin for seller"

  context_ "with JSON request" do
  test "logs and renders JSON response" do
            expect(Rails.logger).to receive(:warn).with(
              "Pundit::NotAuthorizedError for DummyPolicy by User ID #{user_with_role_for_seller.id} for Seller ID #{seller.id}: not allowed to action? this Symbol"
            )

            get :action, format: :json

            expect(response).to have_http_status(:unauthorized)
            expect(response.parsed_body["success"]).to eq(false)
            expect(response.parsed_body["error"]).to eq("Your current role as Admin cannot perform this action.")
          end
        end

  context_ "with JS request" do
  test "logs and renders JSON response" do
            expect(Rails.logger).to receive(:warn).with(
              "Pundit::NotAuthorizedError for DummyPolicy by User ID #{user_with_role_for_seller.id} for Seller ID #{seller.id}: not allowed to action? this Symbol"
            )

            get :action, xhr: true

            expect(response).to have_http_status(:unauthorized)
            expect(response.parsed_body["success"]).to eq(false)
            expect(response.parsed_body["error"]).to eq("Your current role as Admin cannot perform this action.")
          end
        end

  context_ "with non-JSON request" do
  test "logs and redirects" do
            expect(Rails.logger).to receive(:warn).with(
              "Pundit::NotAuthorizedError for DummyPolicy by User ID #{user_with_role_for_seller.id} for Seller ID #{seller.id}: not allowed to action? this Symbol"
            )

            get :action

            expect(response).to redirect_to dashboard_path
            expect(flash[:alert]).to eq("Your current role as Admin cannot perform this action.")
          end

  context_ "when account_switched param is present" do
  test "redirects without logging and without flash message" do
              expect(Rails.logger).not_to receive(:warn).with(
                "Pundit::NotAuthorizedError for DummyPolicy by User ID #{user_with_role_for_seller.id} for Seller ID #{seller.id}: not allowed to action? this Symbol"
              )

              get :action, params: { account_switched: "true" }

              expect(response).to redirect_to dashboard_path
              expect(flash[:alert]).not_to eq("Your current role as Admin cannot perform this action.")
            end
          end
        end
      end

  context_ "with action that does not require authentication" do
  test "returns a generic error message" do
          expect(Rails.logger).to receive(:warn).with(
            "Pundit::NotAuthorizedError for PublicDummyPolicy by unauthenticated user: not allowed to public_action? this Symbol"
          )

          get :public_action, format: :json

          expect(response).to have_http_status(:unauthorized)
          expect(response.parsed_body["success"]).to eq(false)
          expect(response.parsed_body["error"]).to eq("You are not allowed to perform this action.")
        end
      end
    end
  end
end
