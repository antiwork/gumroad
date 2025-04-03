# frozen_string_literal: true

require "spec_helper"

describe Impersonate, type: :controller do
  controller(ApplicationController) do
    include Impersonate

    def action
      head :ok
    end
  end

  before do
    routes.draw { get :action, to: "anonymous#action" }
  end

  context "when not authenticated" do
    it "returns appropriate values" do
      get :action

      expect(controller.impersonating?).to eq(false)
      expect(controller.current_user).to be(nil)
      expect(controller.current_api_user).to be(nil)
      expect(controller.logged_in_user).to be(nil)
      expect(controller.impersonating_user).to eq(nil)
      expect(controller.impersonated_user).to eq(nil)
    end
  end

  let(:user) { create(:named_user) }

  context "when authenticated as admin" do
    let(:admin) { create(:named_user, :admin) }

    describe "for web" do
      before do
        sign_in admin
      end

      describe "#impersonate_user" do
        context "when not impersonating" do
          it "returns appropriate values" do
            get :action

            expect(controller.impersonating?).to eq(false)
            expect(controller.current_user).to eq(admin)
            expect(controller.current_api_user).to be(nil)
            expect(controller.logged_in_user).to eq(admin)
            expect(controller.impersonating_user).to eq(nil)
            expect(controller.impersonated_user).to eq(nil)
          end
        end

        context "when impersonating" do
          it "impersonates" do
            controller.impersonate_user(user)
            get :action

            expect(controller.impersonating?).to eq(true)
            expect(controller.current_user).to eq(admin)
            expect(controller.current_api_user).to be(nil)
            expect(controller.logged_in_user).to eq(user)
            expect(controller.impersonating_user).to eq(admin)
            expect(controller.impersonated_user).to eq(user)
          end

          context "when the user is deleted" do
            before do
              controller.impersonate_user(user)
              user.deactivate!
            end

            it "doesn't impersonate" do
              get :action

              expect(controller.impersonating?).to eq(false)
              expect(controller.current_user).to eq(admin)
              expect(controller.current_api_user).to be(nil)
              expect(controller.logged_in_user).to eq(admin)
              expect(controller.impersonating_user).to eq(nil)
              expect(controller.impersonated_user).to eq(nil)
            end
          end
        end
      end

      describe "#stop_impersonating_user" do
        before do
          controller.impersonate_user(user)
          expect(controller.impersonating?).to eq(true)
        end

        it "stops impersonating" do
          controller.stop_impersonating_user
          get :action

          expect(controller.impersonating?).to eq(false)
          expect(controller.current_user).to eq(admin)
          expect(controller.current_api_user).to be(nil)
          expect(controller.logged_in_user).to eq(admin)
          expect(controller.impersonating_user).to eq(nil)
          expect(controller.impersonated_user).to eq(nil)
        end
      end

      describe "#impersonated_user" do
        context "when not impersonating" do
          it "returns nil" do
            get :action
            expect(controller.impersonated_user).to be(nil)
          end
        end

        context "when impersonating" do
          before do
            controller.impersonate_user(user)
          end

          it "returns the user" do
            get :action
            expect(controller.impersonated_user).to eq(user)
          end

          context "when the user is deleted" do
            before do
              user.deactivate!
            end

            it "returns nil" do
              get :action
              expect(controller.impersonated_user).to be(nil)
            end
          end

          context "when the user is suspended for fraud" do
            before do
              user.flag_for_fraud!(author_id: admin.id)
              user.suspend_for_fraud!(author_id: admin.id)
            end

            it "returns nil" do
              get :action
              expect(controller.impersonated_user).to be(nil)
            end
          end

          context "when the user is suspended for ToS violation" do
            before do
              user.flag_for_tos_violation!(author_id: admin.id, product_id: create(:product, user:).id)
              user.suspend_for_tos_violation!(author_id: admin.id)
            end

            it "returns nil" do
              get :action
              expect(controller.impersonated_user).to be(nil)
            end
          end
        end
      end
    end

    describe "for mobile API" do
      let(:application) { create(:oauth_application) }
      let(:access_token) do
        create(
          "doorkeeper/access_token",
          application:,
          resource_owner_id: admin.id,
          scopes: "creator_api"
        ).token
      end
      let(:params) do
        {
          mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN,
          access_token:
        }
      end

      before do
        @request.params["access_token"] = access_token
      end

      describe "#impersonate_user" do
        it "impersonates user" do
          controller.impersonate_user(user)

          get :action
          expect(controller.impersonating?).to eq(true)
          expect(controller.current_user).to be(nil)
          expect(controller.current_api_user).to eq(admin)
          expect(controller.logged_in_user).to eq(user)
          expect(controller.impersonating_user).to eq(admin)
          expect(controller.impersonated_user).to eq(user)
        end
      end

      describe "#stop_impersonating_user" do
        before do
          controller.impersonate_user(user)
          expect(controller.impersonating?).to eq(true)
        end

        it "stops impersonating user" do
          controller.stop_impersonating_user

          get :action
          expect(controller.impersonating?).to eq(false)
          expect(controller.current_user).to be(nil)
          expect(controller.current_api_user).to eq(admin)
          expect(controller.logged_in_user).to be(nil)
          expect(controller.impersonating_user).to eq(nil)
          expect(controller.impersonated_user).to eq(nil)
        end
      end
    end
  end

  context "when authenticated as regular user" do
    let(:other_user) { create(:named_user) }

    before do
      sign_in other_user
      controller.impersonate_user(user)
    end

    it "doesn't impersonate" do
      get :action

      expect(controller.impersonating?).to eq(false)
      expect(controller.current_user).to eq(other_user)
      expect(controller.current_api_user).to be(nil)
      expect(controller.logged_in_user).to eq(other_user)
      expect(controller.impersonating_user).to eq(nil)
      expect(controller.impersonated_user).to eq(nil)
    end
  end
end
