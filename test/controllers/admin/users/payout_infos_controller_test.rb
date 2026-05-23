# frozen_string_literal: true

require "test_helper"
require "shared_examples/admin_base_controller_concern"

class AdminUsersPayoutInfosControllerTest < ActionController::TestCase
  self.described_class = Admin::Users::PayoutInfosController
  tests Admin::Users::PayoutInfosController



  context_ Admin::Users::PayoutInfosController do
    it_behaves_like "inherits from Admin::BaseController"

    let(:admin_user) { create(:admin_user) }
    let(:user) { create(:user) }

    before do
      sign_in admin_user
    end

  context_ "GET 'show'" do
  test "returns the user's payout info as JSON" do
        get :show, params: { user_external_id: user.external_id }, format: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body).to include("active_bank_account" => nil)
      end
    end
  end
end
