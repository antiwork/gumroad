# frozen_string_literal: true

require "test_helper"
require "shared_examples/admin_base_controller_concern"

class AdminUsersStatsControllerTest < ActionController::TestCase
  self.described_class = Admin::Users::StatsController
  tests Admin::Users::StatsController



  context_ Admin::Users::StatsController do
    it_behaves_like "inherits from Admin::BaseController"

    let(:admin_user) { create(:admin_user) }
    let(:user) { create(:user) }

    before do
      sign_in admin_user
    end

  context_ "GET 'index'" do
      let(:product) { create(:product, user: user, price_cents: 10_000) }

  test "returns the user's stats as JSON" do
        get :index, params: { user_external_id: user.external_id }, format: :json

        expect(response).to have_http_status(:success)

        expect(response.parsed_body).to eq(
          "total" => "$0",
          "balance" => "$0",
          "chargeback_volume" => "NA",
          "chargeback_count" => "NA"
        )
      end
    end
  end
end
