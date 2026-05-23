# frozen_string_literal: true

require "test_helper"

class ApiMobileBaseControllerTest < ActionController::TestCase
  self.described_class = Api::Mobile::BaseController
  tests Api::Mobile::BaseController



  context_ Api::Mobile::BaseController do
    let(:application) { create(:oauth_application) }
    let(:admin_user) { create(:admin_user) }
    let(:access_token) do
      create(
        "doorkeeper/access_token",
        application:,
        resource_owner_id: admin_user.id,
        scopes: "creator_api"
      ).token
    end
    let(:params) do
      {
        mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN,
        access_token:
      }
    end

    controller(Api::Mobile::BaseController) do
      def index
        head :ok
      end
    end

  context_ "as admin user" do
      let(:user) { create(:user) }

      before do
        @request.params["access_token"] = access_token
      end

  test "impersonates" do
        controller.impersonate_user(user)
        get(:index, params:)

        expect(controller.current_resource_owner).to eq(user)
      end
    end
  end
end
