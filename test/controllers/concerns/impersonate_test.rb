# frozen_string_literal: true

require "test_helper"

class ImpersonateTest < ActionController::TestCase
  self.described_class = Impersonate



  context_ Impersonate, type: :controller do
    controller(ApplicationController) do
      include Impersonate

      def action
        head :ok
      end
    end

    before do
      routes.draw { get :action, to: "anonymous#action" }
    end

  context_ "when not authenticated" do
  test "returns appropriate values" do
        get :action

        expect(controller.impersonating?).to eq(false)
        expect(controller.current_user).to be(nil)
        expect(controller.current_api_user).to be(nil)
        expect(controller.logged_in_user).to be(nil)
        expect(controller.impersonating_user).to eq(nil)
        expect(controller.impersonated_user).to eq(nil)
      end

  test "handles reset_impersonated_user without raising" do
        expect { controller.stop_impersonating_user }.not_to raise_error
      end
    end

    let(:user) { create(:named_user) }

  context_ "when authenticated as admin" do
      let(:admin) { create(:named_user, :admin) }

  context_ "for web" do
        before do
          sign_in admin
        end

  context_ "#impersonate_user" do
  context_ "when not impersonating" do
  test "returns appropriate values" do
              get :action

              expect(controller.impersonating?).to eq(false)
              expect(controller.current_user).to eq(admin)
              expect(controller.current_api_user).to be(nil)
              expect(controller.logged_in_user).to eq(admin)
              expect(controller.impersonating_user).to eq(nil)
              expect(controller.impersonated_user).to eq(nil)
            end
          end

  context_ "when impersonating" do
  test "impersonates" do
              controller.impersonate_user(user)
              get :action

              expect(controller.impersonating?).to eq(true)
              expect(controller.current_user).to eq(admin)
              expect(controller.current_api_user).to be(nil)
              expect(controller.logged_in_user).to eq(user)
              expect(controller.impersonating_user).to eq(admin)
              expect(controller.impersonated_user).to eq(user)
            end

  context_ "when the user is deleted" do
              before do
                controller.impersonate_user(user)
                user.deactivate!
              end

  test "doesn't impersonate" do
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

  context_ "#stop_impersonating_user" do
          before do
            controller.impersonate_user(user)
            expect(controller.impersonating?).to eq(true)
          end

  test "stops impersonating" do
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

  context_ "#impersonated_user" do
  context_ "when not impersonating" do
  test "returns nil" do
              get :action
              expect(controller.impersonated_user).to be(nil)
            end
          end

  context_ "when impersonating" do
            before do
              controller.impersonate_user(user)
            end

  test "returns the user" do
              get :action
              expect(controller.impersonated_user).to eq(user)
            end

  context_ "when the user is deleted" do
              before do
                user.deactivate!
              end

  test "returns nil" do
                get :action
                expect(controller.impersonated_user).to be(nil)
              end
            end

  context_ "when the user is suspended for fraud" do
              before do
                user.flag_for_fraud!(author_id: admin.id)
                user.suspend_for_fraud!(author_id: admin.id)
              end

  test "returns the user" do
                get :action
                expect(controller.impersonated_user).to eq(user)
              end
            end

  context_ "when the user is suspended for ToS violation" do
              before do
                user.flag_for_tos_violation!(author_id: admin.id, product_id: create(:product, user:).id)
                user.suspend_for_tos_violation!(author_id: admin.id)
              end

  test "returns the user" do
                get :action
                expect(controller.impersonated_user).to eq(user)
              end
            end
          end
        end
      end

  context_ "for mobile API" do
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

  context_ "#impersonate_user" do
  test "impersonates user" do
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

  context_ "#stop_impersonating_user" do
          before do
            controller.impersonate_user(user)
            expect(controller.impersonating?).to eq(true)
          end

  test "stops impersonating user" do
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

  context_ "when authenticated as regular user" do
      let(:other_user) { create(:named_user) }

      before do
        sign_in other_user
        controller.impersonate_user(user)
      end

  test "doesn't impersonate" do
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
end
